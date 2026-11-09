// sweet-mcmdiag: reproduce the container lookup that lsd's -[MIDaemonConfiguration init] does for
// "com.apple.installd" and log the exact MCM error. Logs to /var/mobile/Library/Logs/sweet-mcmdiag.log.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>
#include <dlfcn.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <spawn.h>
#include <pwd.h>
#include <grp.h>
extern char **environ;
#include <xpc/xpc.h>

static FILE *lf;
static void say(const char *fmt, ...) {
	va_list ap; va_start(ap, fmt);
	fprintf(lf, "[%ld] ", (long)time(NULL));
	vfprintf(lf, fmt, ap); fputc('\n', lf); fflush(lf); va_end(ap);
}

typedef void *(*create_t)(void);
typedef void (*setclass_t)(void *, uint32_t);
typedef void (*setids_t)(void *, xpc_object_t);
typedef void (*setpersona_t)(void *, const char *);
typedef void (*setflags_t)(void *, uint64_t);
typedef void *(*single_t)(void *);
typedef void *(*lasterr_t)(void *);
typedef char *(*errdesc_t)(void *);
typedef const char *(*getpath_t)(void *);
typedef void (*free_t)(void *);

static create_t q_create; static setclass_t q_class; static setids_t q_ids; static setpersona_t q_persona;
static setflags_t q_flags; static single_t q_single; static lasterr_t q_lasterr; static errdesc_t e_desc;
static getpath_t c_path; static free_t q_free;

static void try_one(const char *label, uint32_t cls, const char *ident, int persona, uint64_t flags) {
	void *q = q_create();
	if (!q) { say("%s: container_query_create returned NULL", label); return; }
	q_class(q, cls);
	xpc_object_t s = xpc_string_create(ident);
	q_ids(q, s);
	if (persona) q_persona(q, "com.apple.containermanager.primary-persona");
	if (flags) q_flags(q, flags);
	void *r = q_single(q);
	if (r) {
		say("%s: class %u id %s -> OK path=%s", label, cls, ident, c_path ? c_path(r) : "?");
	} else {
		void *e = q_lasterr ? q_lasterr(q) : NULL;
		char *d = (e && e_desc) ? e_desc(e) : NULL;
		say("%s: class %u id %s -> NULL error=%s", label, cls, ident, d ? d : "(none)");
	}
	q_free(q);
}

static void do_round(int n) {
	say("---- round %d ----", n);
	try_one("exact-init", 10, "com.apple.installd", 1, 0x900000001ULL);
	try_one("no-persona", 10, "com.apple.installd", 0, 0x900000001ULL);
	try_one("plain", 10, "com.apple.installd", 0, 0);
	try_one("sanity-lsd", 12, "com.apple.lsd", 1, 0);
	try_one("sanity-lsd-plain", 12, "com.apple.lsd", 0, 0);
	for (uint32_t c = 1; c <= 15; c++) if (c != 10) try_one("sweep", c, "com.apple.installd", 0, 0);
	try_one("mobile-installation", 10, "com.apple.mobile_installation", 0, 0);
}

static void run_child(const char *self, const char *label) {
	char *args[] = { (char *)self, (char *)"child", NULL };
	pid_t p = 0;
	int rc = posix_spawn(&p, self, NULL, NULL, args, environ);
	if (rc != 0) { say("%s: posix_spawn failed rc=%d", label, rc); return; }
	int st = 0; waitpid(p, &st, 0);
	say("%s: real MIDaemonConfiguration sharedInstance in exec'd child (uid %d): status=%#x exited=%d code=%d signaled=%d sig=%d",
		label, getuid(), st, WIFEXITED(st), WEXITSTATUS(st), WIFSIGNALED(st), WTERMSIG(st));
}

int main(int argc, char **argv) {
	@autoreleasepool {
		if (argc > 1 && !strcmp(argv[1], "child")) {
			dlopen("/System/Library/PrivateFrameworks/InstalledContentLibrary.framework/InstalledContentLibrary", RTLD_NOW);
			Class c = NSClassFromString(@"MIDaemonConfiguration");
			if (!c) _exit(90);
			[c performSelector:NSSelectorFromString(@"sharedInstance")];
			_exit(0);
		}
		mkdir("/var/mobile/Library/Logs", 0755);
		lf = fopen("/var/mobile/Library/Logs/sweet-mcmdiag2.log", "a");
		if (!lf) lf = stderr;
		say("start pid=%d uid=%d", getpid(), getuid());
		void *h = RTLD_DEFAULT;
		q_create = dlsym(h, "container_query_create"); q_class = dlsym(h, "container_query_set_class");
		q_ids = dlsym(h, "container_query_set_identifiers"); q_persona = dlsym(h, "container_query_set_persona_unique_string");
		q_flags = dlsym(h, "container_query_operation_set_flags"); q_single = dlsym(h, "container_query_get_single_result");
		q_lasterr = dlsym(h, "container_query_get_last_error"); e_desc = dlsym(h, "container_error_copy_unlocalized_description");
		c_path = dlsym(h, "container_get_path"); q_free = dlsym(h, "container_query_free");
		if (!q_create || !q_class || !q_ids || !q_single || !q_free) { say("missing symbols, exiting"); return 0; }
		sleep(90);
		say("==== as root ====");
		try_one("root exact-init", 10, "com.apple.installd", 1, 0x900000001ULL);
		run_child(argv[0], "root");
		struct passwd *pw = getpwnam("mobile");
		uid_t mu = pw ? pw->pw_uid : 501; gid_t mg = pw ? pw->pw_gid : 501;
		int r1 = initgroups("mobile", mg), r2 = setgid(mg), r3 = setuid(mu);
		say("==== dropped to mobile: initgroups=%d setgid=%d setuid=%d now uid=%d euid=%d ====", r1, r2, r3, getuid(), geteuid());
		do_round(1);
		run_child(argv[0], "mobile");
		sleep(30);
		do_round(2);
		say("done");
	}
	return 0;
}
