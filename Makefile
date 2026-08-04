.PHONY: bootstrap generate pins build test uitest format lint

# The simulator the local UI suite drives. Override for another device:
# `make uitest DEVICE='iPhone 17'`.
DEVICE ?= iPhone 17 Pro

bootstrap:
	Scripts/bootstrap.sh

generate:
	xcodegen generate

# Refresh the pins Xcode Cloud builds against. Run this after changing any
# dependency version — `Config/Package.resolved` is committed precisely because
# the build machine cannot produce it (automatic resolution is disabled there,
# so even `xcodebuild -resolvePackageDependencies` is refused; see
# ci_scripts/ci_post_clone.sh). A stale file fails the Xcode Cloud build.
pins: generate
	xcodebuild -resolvePackageDependencies -project Hive.xcodeproj -scheme Hive
	cp Hive.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Config/Package.resolved
	@git diff --stat -- Config/Package.resolved

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

# The conversation shape gate: eight conversation shapes driven through a real keyboard
# on a real simulator, minutes rather than seconds. Deliberately not a CI gate on pull
# requests — run it here when the work touches the conversation shell, the message list,
# the composer, or the keyboard. See .github/workflows/conversation-ui.yml.
uitest: generate
	xcodebuild test -project Hive.xcodeproj -scheme ConversationUITests \
		-destination 'platform=iOS Simulator,name=$(DEVICE)' \
		-skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO

format:
	swiftformat .

lint:
	swiftlint
