// sweet-regplugins: register the system PosterKit wallpaper providers (and optionally other system plug-ins) with LaunchServices,
// then ask PlugInKit (via NSExtension, the same question PosterBoard asks) who provides "com.apple.posterkit.provider".
// Tries several registration strategies in order and logs the outcome of each to /var/mobile/Library/Logs/sweet-regplugins.log.
// Always exits 0 (launchd job must not respawn it in a loop). Installed in place of sweet-lsrebuild (same path, same size).
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
- (BOOL)registerPlugin:(NSURL *)url;
- (BOOL)registerApplicationDictionary:(NSDictionary *)d;
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

static NSString *const kPoster = @"com.apple.posterkit.provider";

// How many poster providers does PlugInKit report right now? (what PosterBoard sees)
static int queryProviders(void) {
	__block int n = -1;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	@try {
		Class ec = NSClassFromString(@"NSExtension");
		SEL es = NSSelectorFromString(@"extensionsWithMatchingAttributes:completion:");
		if (!ec || ![ec respondsToSelector:es]) {
			say("    NSExtension query API missing");
			return -4;
		}
		void (*send)(id, SEL, NSDictionary *, void (^)(NSArray *, NSError *)) = (void *)objc_msgSend;
		send(ec, es, @{@"NSExtensionPointIdentifier": kPoster}, ^(NSArray *exts, NSError *err) {
			n = (int)[exts count];
			for (id e in exts) say("    provider: %s", [[e description] UTF8String]);
			if (err) say("    query error: %s", [[err description] UTF8String]);
			dispatch_semaphore_signal(sem);
		});
	} @catch (NSException *ex) {
		say("    query exception: %s", [[ex description] UTF8String]);
		return -2;
	}
	if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC)) != 0) {
		say("    query timed out");
		return -3;
	}
	return n;
}

static void collect(NSString *dir, NSString *ext, NSMutableArray *out) {
	NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
	for (NSString *it in items) {
		if (![it hasSuffix:ext]) continue;
		NSString *plugdir = [[dir stringByAppendingPathComponent:it] stringByAppendingPathComponent:@"PlugIns"];
		NSArray *pl = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:plugdir error:nil];
		for (NSString *p in pl) {
			if ([p hasSuffix:@".appex"]) [out addObject:[plugdir stringByAppendingPathComponent:p]];
		}
	}
}

int main(int argc, char **argv) {
	@autoreleasepool {
		mkdir("/var/mobile/Library/Logs", 0755);
		lf = fopen("/var/mobile/Library/Logs/sweet-regplugins.log", "a");
		if (!lf) lf = stderr;
		say("start pid=%d uid=%d", getpid(), getuid());
		sleep(45); // let lsd / pkd settle after boot
		say("after settle");

		NSMutableArray *cands = [NSMutableArray array];
		collect(@"/System/Library/PrivateFrameworks", @".framework", cands);
		collect(@"/System/Library/Frameworks", @".framework", cands);
		collect(@"/System/Library/CoreServices", @".app", cands);
		collect(@"/Applications", @".app", cands);

		NSMutableArray *posters = [NSMutableArray array];
		NSMutableDictionary *info = [NSMutableDictionary dictionary];
		for (NSString *p in cands) {
			NSDictionary *ip = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Info.plist"]];
			NSString *pt = ip[@"NSExtension"][@"NSExtensionPointIdentifier"];
			if ([pt isEqualToString:kPoster]) {
				[posters addObject:p];
				info[p] = ip;
				say("poster appex: %s (%s)", [p UTF8String], [ip[@"CFBundleIdentifier"] UTF8String]);
			}
		}
		say("candidates=%lu posters=%lu", (unsigned long)[cands count], (unsigned long)[posters count]);

		LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
		int before = queryProviders();
		say("providers before: %d", before);

		// strategy 1: registerPlugin: with the appex URL
		int ok1 = 0;
		for (NSString *p in posters) {
			BOOL r = NO;
			@try { r = [ws registerPlugin:[NSURL fileURLWithPath:p]]; } @catch (NSException *e) { say("  S1 exception %s", [[e description] UTF8String]); }
			say("  S1 registerPlugin %s -> %d", [[p lastPathComponent] UTF8String], r);
			ok1 += r;
		}
		int a1 = queryProviders();
		say("S1 done ok=%d providers=%d", ok1, a1);

		if (a1 <= 0) {
			// strategy 2: top-level plugin dictionary through registerApplicationDictionary:
			int ok2 = 0;
			for (NSString *p in posters) {
				NSDictionary *ip = info[p];
				NSString *bid = ip[@"CFBundleIdentifier"];
				NSString *owner = @"com.apple.PosterBoard";
				if ([p hasPrefix:@"/Applications/"] || [p hasPrefix:@"/System/Library/CoreServices/"]) {
					NSString *app = [[p stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
					NSDictionary *aip = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
					if (aip[@"CFBundleIdentifier"]) owner = aip[@"CFBundleIdentifier"];
				}
				NSDictionary *d = @{
					@"ApplicationType": @"PluginKitPlugin",
					@"CFBundleIdentifier": bid,
					@"CodeInfoIdentifier": bid,
					@"CompatibilityState": @0,
					@"IsContainerized": @NO,
					@"Path": p,
					@"PluginOwnerBundleID": owner,
					@"SignerOrganization": @"Apple Inc.",
					@"SignatureVersion": @132352,
					@"SignerIdentity": @"Apple iPhone OS Application Signing",
				};
				BOOL r = NO;
				@try { r = [ws registerApplicationDictionary:d]; } @catch (NSException *e) { say("  S2 exception %s", [[e description] UTF8String]); }
				say("  S2 registerApplicationDictionary %s -> %d", [bid UTF8String], r);
				ok2 += r;
			}
			int a2 = queryProviders();
			say("S2 done ok=%d providers=%d", ok2, a2);
		}
		say("finished");
	}
	return 0;
}
