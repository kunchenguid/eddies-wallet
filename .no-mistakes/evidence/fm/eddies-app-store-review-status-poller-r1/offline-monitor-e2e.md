# Offline App Store review monitor end-to-end evidence

This deterministic, credential-free simulation invoked the monitor's real
`main()` entry point with in-memory App Store Connect fixtures and a GitHub
issue API fixture. It made no network request and handled no real credential.

```text
first scheduled poll: exit=0 apple_requests=1
ASC_REVIEW_MONITOR version=0.1 build=12.1 category=in-review state=IN_REVIEW notification=sent
repeat scheduled poll: exit=0 apple_requests=1
ASC_REVIEW_MONITOR version=0.1 build=12.1 category=in-review state=IN_REVIEW notification=deduplicated
status transition poll: exit=0 apple_requests=1
ASC_REVIEW_MONITOR version=0.1 build=12.1 category=action-required state=REJECTED notification=sent
closed-cycle scheduled poll: exit=0 apple_requests=0
ASC_REVIEW_MONITOR version=0.1 build=12.1 notification=disabled
trusted manual rearm: exit=0 apple_requests=1
ASC_REVIEW_MONITOR version=0.1 build=12.1 category=action-required state=REJECTED notification=sent
issue: App Store review monitor state: version 0.1, build 12.1 state=open
comments:
- Review status changed: version 0.1, build 12.1, in-review (IN_REVIEW).
- Review status changed: version 0.1, build 12.1, action-required (REJECTED).
- Review status changed: version 0.1, build 12.1, action-required (REJECTED).
```

Every simulated Apple request used this exact read endpoint:

```text
GET /v1/apps/6795664301/appStoreVersions?filter%5BversionString%5D=0.1&filter%5Bplatform%5D=IOS&fields%5BappStoreVersions%5D=versionString%2CappVersionState%2Cplatform%2Cbuild&include=build&fields%5Bbuilds%5D=version%2Cexpired&limit=50
```

The closed issue skipped JWT creation and Apple access, the repeated state
created no second transition comment, and trusted manual rearm reopened the
same issue and deliberately notified again.

The focused pagination boundary probe also rejected a different app ID, a
different marketing version, and altered sparse/include parameters:

```text
App Store Connect returned unsafe pagination URL: /v1/apps/OTHER/appStoreVersions?filter[versionString]=0.1
App Store Connect returned unsafe pagination URL: /v1/apps/6795664301/appStoreVersions?filter[versionString]=0.2
App Store Connect returned unsafe pagination URL: /v1/apps/6795664301/appStoreVersions?...&include=build&include=builds
```
