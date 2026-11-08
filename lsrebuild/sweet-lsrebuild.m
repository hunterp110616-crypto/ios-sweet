// sweet-lsrebuild: ask LaunchServices to rebuild its application/plugin registry for the system apps.
// The SWEET iOS root skips installd's first-boot registration, so system plug-ins (PosterBoard wallpaper providers, ...)
// never reach LaunchServices/PlugInKit. A real iPhone gets them registered by this same private call.
// Runs as a launchd job at boot (retried until it succeeds), logs to /var/mobile/Library/Logs/sweet-lsrebuild.log.
#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
@end

@interface LSApplicationWorkspace (SweetPrivate)
- (BOOL)_LSPrivateRebuildApplicationDatabasesForSystemApps:(BOOL)systemApps internal:(BOOL)internal user:(BOOL)user;
@end

static FILE *logf_;

static void say(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	time_t t = time(NULL);
	fprintf(logf_, "[%ld] ", (long)t);
	vfprintf(logf_, fmt, ap);
	fputc('\n', logf_);
	fflush(logf_);
	va_end(ap);
}

int main(int argc, char **argv) {
	@autoreleasepool {
		mkdir("/var/mobile/Library/Logs", 0755);
		logf_ = fopen("/var/mobile/Library/Logs/sweet-lsrebuild.log", "a");
		if (!logf_) logf_ = stderr;
		say("start pid=%d uid=%d", getpid(), getuid());

		const char *marker = "/var/db/sweet-lsrebuild.done";
		if (access(marker, F_OK) == 0 && !(argc > 1 && strcmp(argv[1], "-f") == 0)) {
			say("marker present, nothing to do");
			return 0;
		}

		LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
		SEL sel = @selector(_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:);
		if (![ws respondsToSelector:sel]) {
			say("FAIL: rebuild selector missing");
			return 2;
		}
		BOOL ok = NO;
		@try {
			ok = [ws _LSPrivateRebuildApplicationDatabasesForSystemApps:YES internal:YES user:YES];
		} @catch (NSException *e) {
			say("EXCEPTION: %s", [[e description] UTF8String]);
		}
		say("rebuild returned %d", ok);

		// report what LaunchServices knows now
		@try {
			NSArray *apps = [ws performSelector:@selector(allInstalledApplications)];
			say("applications: %lu", (unsigned long)[apps count]);
		} @catch (NSException *e) {
			say("apps query failed: %s", [[e description] UTF8String]);
		}
		@try {
			NSArray *plugins = [ws performSelector:@selector(installedPlugins)];
			say("plugins: %lu", (unsigned long)[plugins count]);
			NSUInteger posters = 0;
			for (id p in plugins) {
				NSString *ident = nil;
				@try { ident = [p valueForKey:@"pluginIdentifier"]; } @catch (NSException *e) {}
				NSString *pt = nil;
				@try { pt = [p valueForKey:@"protocol"]; } @catch (NSException *e) {}
				if ([pt hasPrefix:@"com.apple.posterkit"] || [ident containsString:@"Poster"]) {
					posters++;
					say("  poster plugin: %s (%s)", [ident UTF8String], [pt UTF8String]);
				}
			}
			say("poster plugins: %lu", (unsigned long)posters);
		} @catch (NSException *e) {
			say("plugins query failed: %s", [[e description] UTF8String]);
		}

		if (ok) {
			FILE *m = fopen(marker, "w");
			if (m) { fputs("done\n", m); fclose(m); }
			say("done, marker written");
			return 0;
		}
		say("will be retried");
		return 1;
	}
}
