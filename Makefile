.PHONY: bootstrap generate build test format lint

bootstrap:
	Scripts/bootstrap.sh

generate:
	xcodegen generate

test:
	swift test --package-path Packages/NostrCore
	swift test --package-path Packages/BuzzKit

build: generate
	xcodebuild build -project Hive.xcodeproj -scheme Hive \
		-destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

format:
	swiftformat .

lint:
	swiftlint
