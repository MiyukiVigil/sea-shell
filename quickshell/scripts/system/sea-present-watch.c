/* Passive Xwayland Present observer. No window, rendering, injection or mode changes.
 * Build: cc -O2 -Wall -Wextra sea-present-watch.c -o sea-present-watch -lX11 -lXpresent
 * Usage: sea-present-watch WINDOW_ID SECONDS > present.csv
 * --root instead of WINDOW_ID is a bounded connection self-check (no frame test).
 */
#include <X11/Xlib.h>
#include <X11/extensions/Xpresent.h>
#include <errno.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static volatile sig_atomic_t stopped;
static int xerror;
static void stop(int signo) { (void)signo; stopped = 1; }
static int error_handler(Display *d, XErrorEvent *e) {
    char text[256]; XGetErrorText(d, e->error_code, text, sizeof(text));
    fprintf(stderr, "X11 error: %s\n", text); xerror = 1; return 0;
}
static double now(clockid_t clock) {
    struct timespec t; clock_gettime(clock, &t); return t.tv_sec + t.tv_nsec / 1e9;
}
int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "Usage: %s WINDOW_ID|--root SECONDS (1..3600)\n", argv[0]); return 2; }
    char *end; errno = 0; long seconds = strtol(argv[2], &end, 10);
    if (errno || *end || seconds < 1 || seconds > 3600) return 2;
    Display *d = XOpenDisplay(NULL);
    if (!d) { fprintf(stderr, "Cannot connect to the current Xwayland display.\n"); return 1; }
    XSetErrorHandler(error_handler);
    Window window;
    if (!strcmp(argv[1], "--root")) window = DefaultRootWindow(d);
    else {
        errno = 0; window = strtoul(argv[1], &end, 0);
        if (errno || *end || !window) { XCloseDisplay(d); return 2; }
    }
    XWindowAttributes attrs;
    if (!XGetWindowAttributes(d, window, &attrs) || xerror) { XCloseDisplay(d); return 1; }
    int opcode, event_base, error_base;
    if (!XPresentQueryExtension(d, &opcode, &event_base, &error_base)) {
        fprintf(stderr, "Present extension unavailable.\n"); XCloseDisplay(d); return 1;
    }
    XID subscription = XPresentSelectInput(d, window, PresentCompleteNotifyMask);
    XSync(d, False);
    if (xerror) { XCloseDisplay(d); return 1; }
    signal(SIGINT, stop); signal(SIGTERM, stop); signal(SIGHUP, stop);
    double deadline = now(CLOCK_MONOTONIC) + seconds;
    uint64_t previous_ust = 0, previous_msc = 0, count = 0;
    puts("received_epoch,received_monotonic,serial,ust_us,msc,interval_us,msc_gap,mode");
    while (!stopped && !xerror && now(CLOCK_MONOTONIC) < deadline) {
        if (!XPending(d)) {
            struct pollfd fd = { .fd = ConnectionNumber(d), .events = POLLIN };
            int ready = poll(&fd, 1, 100);
            if (ready < 0 && errno != EINTR) break;
            if (ready > 0 && (fd.revents & (POLLERR | POLLHUP | POLLNVAL))) break;
            continue;
        }
        XEvent event; XNextEvent(d, &event);
        if (event.type != GenericEvent || event.xcookie.extension != opcode ||
            !XGetEventData(d, &event.xcookie)) continue;
        if (event.xcookie.evtype == PresentCompleteNotify) {
            XPresentCompleteNotifyEvent *p = event.xcookie.data;
            if (p->window == window && p->kind == PresentCompleteKindPixmap) {
                uint64_t dt = previous_ust && p->ust >= previous_ust ? p->ust - previous_ust : 0;
                uint64_t gap = previous_msc && p->msc >= previous_msc ? p->msc - previous_msc : 0;
                printf("%.6f,%.6f,%u,%"PRIu64",%"PRIu64",%"PRIu64",%"PRIu64",%u\n",
                       now(CLOCK_REALTIME), now(CLOCK_MONOTONIC), p->serial_number,
                       p->ust, p->msc, dt, gap, p->mode);
                fflush(stdout); previous_ust = p->ust; previous_msc = p->msc; count++;
            }
        }
        XFreeEventData(d, &event.xcookie);
    }
    XPresentFreeInput(d, window, subscription); XSync(d, False); XCloseDisplay(d);
    fprintf(stderr, "Observed %"PRIu64" presentation completions.\n", count);
    return xerror ? 1 : 0;
}
