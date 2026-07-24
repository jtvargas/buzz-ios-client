.PHONY: bootstrap generate build test format lint

bootstrap:
	Scripts/bootstrap.sh

generate:
	xcodegen generate

# Release config: current Swift toolchains (Xcode 26.2+) abort -Onone test
# runs in the connection suites — an environmental codegen defect, see
# .github/workflows/ci.yml. Same assertions either way.
test:
	swift test -c release --package-path Packages/NostrCore
	swift test -c release --package-path Packages/BuzzKit

build: generate
	xcodebuild build -project Hive.xcodeproj -scheme Hive \
		-destination 'generic/platform=iOS Simulator' \
		-skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO

format:
	swiftformat .

lint:
	swiftlint
