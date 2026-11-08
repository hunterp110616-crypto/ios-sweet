// sweet-lsrebuild2: one more full LaunchServices rebuild (now that PlugInKit's extension cache is trusted), then ask
// PlugInKit (the way PosterBoard does) who provides "com.apple.posterkit.provider". Logs to
// /var/mobile/Library/Logs/sweet-lsrebuild2.log. Runs once (marker /var/db/sweet-lsrebuild2.done), always exits 0.
#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <dispatch/dispatch.h>
#include <objc/message.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)_LSPrivateRebuildApplicationDatabasesForSystemApps:(BOOL)a internal:(BOOL)b user:(BOOL)c;
@end

static FILE *lf;
static void say(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(lf, "[%ld] ", (long)time(NULL));
	vfprintf(lf, fmt, ap);
	fputc('\n', lf);
	fflush(lf);
	va_end(ap);
}

static int queryProviders(NSString *point) {
	__block int n = -1;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	@try {
		Class ec = NSClassFromString(@"NSExtension");
		SEL es = NSSelectorFromString(@"extensionsWithMatchingAttributes:completion:");
		if (!ec || ![ec respondsToSelector:es]) { say("  NSExtension API missing"); return -4; }
		void (*send)(id, SEL, NSDictionary *, void (^)(NSArray *, NSError *)) = (void *)objc_msgSend;
		send(ec, es, @{@"NSExtensionPointIdentifier": point}, ^(NSArray *exts, NSError *err) {
			n = (int)[exts count];
			for (id e in exts) say("    provider: %s", [[e description] UTF8String]);
			if (err) say("    query error: %s", [[err description] UTF8String]);
			dispatch_semaphore_signal(sem);
		});
	} @catch (NSException *ex) {
		say("  query exception: %s", [[ex description] UTF8String]);
		return -2;
	}
	if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC)) != 0) { say("  query timed out"); return -3; }
	return n;
}

int main(int argc, char **argv) {
	@autoreleasepool {
		mkdir("/var/mobile/Library/Logs", 0755);
		lf = fopen("/var/mobile/Library/Logs/sweet-lsrebuild2.log", "a");
		if (!lf) lf = stderr;
		say("start pid=%d uid=%d", getpid(), getuid());
		const char *marker = "/var/db/sweet-lsrebuild2.done";
		sleep(30);
		if (access(marker, F_OK) == 0) {
			say("marker present: only querying");
			say("posterkit providers now: %d", queryProviders(@"com.apple.posterkit.provider"));
			return 0;
		}
		say("providers before rebuild: %d", queryProviders(@"com.apple.posterkit.provider"));
		LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
		BOOL ok = NO;
		@try { ok = [ws _LSPrivateRebuildApplicationDatabasesForSystemApps:YES internal:YES user:YES]; }
		@catch (NSException *e) { say("EXCEPTION: %s", [[e description] UTF8String]); }
		say("rebuild returned %d", ok);
		say("posterkit providers after rebuild: %d", queryProviders(@"com.apple.posterkit.provider"));
		say("widget providers after rebuild: %d", queryProviders(@"com.apple.widgetkit-extension"));
		FILE *m = fopen(marker, "w");
		if (m) { fputs("done\n", m); fclose(m); }
		say("done, marker written");
	}
	return 0;
}
