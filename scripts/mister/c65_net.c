/* c65_net: the ARM side of the C65 core's MEGA65 Ethernet controller.
 *
 * The DE10-Nano's FPGA has no network port of its own, so the core
 * (rtl/m65_eth.sv) keeps its frame buffers in DDR3 at 0x3FF00000 and this
 * program moves frames between there and the MiSTer's wired port, eth0, with
 * a raw packet socket.  The C65 is then a machine of its own on the LAN, with
 * its own MAC address (the MEGA65's 02:47:53:65:65:65 unless a program sets
 * another): DHCP, the internet and other machines work as on a MEGA65 with a
 * cable.  One thing does not: the MiSTer's own Linux cannot talk to the C65,
 * because frames sent out of eth0 do not come back in.
 *
 * Only while the C65 core (or the z486 core, whose NE2000 card uses the same
 * shared area) is loaded (/tmp/CORENAME) and its controller is running does
 * this touch the shared memory; other cores may use that DDR.
 *
 * Shared area (see rtl/m65_eth.sv): +0 word written by the core (magic 0xE7,
 * version, rx_req, rx_slot, tx_seq, tx_len, flags), +8 word written here
 * (rx_done, tx_done, 0xA5 while running), +0x10 the MAC and $D6E5,
 * +0x800 the TX buffer, +0x1000 four 2K RX buffers.
 *
 * usage: c65_net [interface]      (default eth0; runs in the foreground)
 *
 * build: zig cc -target arm-linux-musleabihf -O2 -s -static -o c65_net c65_net.c
 */
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>
#include <linux/ethtool.h>
#include <linux/sockios.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define SHM_PHYS 0x3FF00000u
#define SHM_SIZE 0x3000u
#define QMAX     16

static volatile uint8_t *shm;
static volatile int quit;
static unsigned char q[QMAX][2048];
static int qlen[QMAX], qhead, qn;

static void on_signal(int s) { (void)s; quit = 1; }

static int core_is_c65(void) {
	char b[32] = {0};
	FILE *f = fopen("/tmp/CORENAME", "r");
	if (!f) return 0;
	if (!fgets(b, sizeof b, f)) b[0] = 0;
	fclose(f);
	b[strcspn(b, "\r\n")] = 0;
	/* the C65's MEGA65 Ethernet and the z486 core's NE2000 use the same area */
	return strcmp(b, "C65") == 0 || strcmp(b, "Z486") == 0;
}

static uint32_t crc32(const unsigned char *d, int n) {
	uint32_t c = 0xFFFFFFFFu;
	for (int i = 0; i < n; i++) {
		c ^= d[i];
		for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & -(c & 1));
	}
	return ~c;
}

int main(int argc, char **argv) {
	const char *ifname = argc > 1 ? argv[1] : "eth0";
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);

	int mfd = open("/dev/mem", O_RDWR | O_SYNC);
	if (mfd < 0) { perror("/dev/mem"); return 1; }
	shm = mmap(NULL, SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, SHM_PHYS);
	if (shm == MAP_FAILED) { perror("mmap"); return 1; }

	int s = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
	if (s < 0) { perror("socket"); return 1; }
	int ifindex = if_nametoindex(ifname);
	if (!ifindex) { fprintf(stderr, "%s: no such interface\n", ifname); return 1; }
	struct sockaddr_ll sll = { .sll_family = AF_PACKET, .sll_protocol = htons(ETH_P_ALL), .sll_ifindex = ifindex };
	if (bind(s, (struct sockaddr *)&sll, sizeof sll) < 0) { perror("bind"); return 1; }
	struct packet_mreq mr = { .mr_ifindex = ifindex, .mr_type = PACKET_MR_PROMISC };
	setsockopt(s, SOL_PACKET, PACKET_ADD_MEMBERSHIP, &mr, sizeof mr);
	fcntl(s, F_SETFL, O_NONBLOCK);
	/* Generic receive offload merges TCP segments arriving back to back into
	 * one frame larger than any the sender sent, and a packet socket gets the
	 * merged frame: too big for the guest (a DOS stack with a 576-byte MTU
	 * drops it).  Hand over frames as they were on the wire. */
	{
		struct ethtool_value ev = { .cmd = ETHTOOL_SGRO, .data = 0 };
		struct ifreq ifr;
		memset(&ifr, 0, sizeof ifr);
		strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
		ifr.ifr_data = (void *)&ev;
		if (ioctl(s, SIOCETHTOOL, &ifr) < 0) perror("GRO off");
	}
	fprintf(stderr, "c65_net: %s, shared memory at 0x%08X\n", ifname, SHM_PHYS);

	int c65 = 0;
	time_t last_check = 0;
	while (!quit) {
		struct pollfd p = { .fd = s, .events = POLLIN };
		poll(&p, 1, 1);

		time_t now = time(NULL);
		if (now != last_check) {
			last_check = now;
			int was = c65;
			c65 = core_is_c65();
			if (was && !c65) qn = 0;
		}

		/* everything that arrived: keep what the C65 would accept */
		unsigned char buf[4096];
		struct sockaddr_ll from;
		socklen_t fl = sizeof from;
		int n;
		while ((n = recvfrom(s, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl)) > 0) {
			fl = sizeof from;
			if (!c65 || from.sll_pkttype == PACKET_OUTGOING || n < 14 || n > 2042) continue;
			if (shm[0] != 0xE7 || !(shm[7] & 1)) continue;
			uint8_t mac[6], d6e5 = shm[0x16];
			for (int i = 0; i < 6; i++) mac[i] = shm[0x10 + i];
			if (!memcmp(buf + 6, mac, 6)) continue;            /* our own frame */
			int bc = !memcmp(buf, "\xFF\xFF\xFF\xFF\xFF\xFF", 6);
			int mc = (buf[0] & 1) && !bc;
			int me = !memcmp(buf, mac, 6);
			if ((d6e5 & 0x01) && !me && !(bc && (d6e5 & 0x10)) && !(mc && (d6e5 & 0x20))) continue;
			if (qn == QMAX) { qhead = (qhead + 1) % QMAX; qn--; }  /* drop the oldest */
			int t = (qhead + qn) % QMAX;
			memcpy(q[t], buf, n);
			qlen[t] = n;
			qn++;
		}
		if (!c65 || shm[0] != 0xE7) continue;
		shm[10] = 0xA5;
		if (!(shm[7] & 1)) continue;

		/* a frame from the C65 */
		uint8_t tx_seq = shm[4];
		if (tx_seq != shm[9]) {
			int len = shm[5] | ((shm[6] & 0x0F) << 8);
			unsigned char f[2048];
			for (int i = 0; i < len; i++) f[i] = shm[0x800 + i];
			if (len < 60) { memset(f + len, 0, 60 - len); len = 60; }
			sendto(s, f, len, 0, (struct sockaddr *)&sll, sizeof sll);
			__sync_synchronize();
			shm[9] = tx_seq;
		}

		/* the core wants a frame and one is waiting */
		uint8_t rx_req = shm[2];
		if (rx_req != shm[8] && qn) {
			unsigned char *f = q[qhead];
			int len = qlen[qhead];
			qhead = (qhead + 1) % QMAX; qn--;
			uint32_t crc = crc32(f, len);
			for (int k = 0; k < 4; k++) f[len + k] = crc >> (8 * k);
			len += 4;
			uint8_t mac[6];
			for (int i = 0; i < 6; i++) mac[i] = shm[0x10 + i];
			int bc = !memcmp(f, "\xFF\xFF\xFF\xFF\xFF\xFF", 6);
			int mc = (f[0] & 1) && !bc;
			int me = !memcmp(f, mac, 6);
			volatile uint8_t *b = shm + 0x1000 + (shm[3] & 3) * 0x800;
			b[0] = len & 0xFF;
			b[1] = ((len >> 8) & 7) | (me << 6) | (bc << 5) | (mc << 4);
			for (int i = 0; i < len; i++) b[2 + i] = f[i];
			__sync_synchronize();
			shm[8] = rx_req;
		}
	}
	if (c65 && shm[0] == 0xE7) shm[10] = 0;
	return 0;
}
