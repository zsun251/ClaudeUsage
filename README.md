# ClaudeUsage

A tiny macOS menu bar app that shows your Claude session and weekly usage, refreshing every 5 minutes and after wake.

It reads the Claude Code sign-in from the login keychain at runtime (and renews the access token when it expires), so Claude Code must be signed in on this Mac. No credentials are stored in this repo.

## Build

```sh
swiftc -O main.swift -o ClaudeUsage
```

## Run at login

```sh
cp com.user.claudeusage.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.claudeusage.plist
```

Edit the path inside the plist if the app is not at `~/Applications/ClaudeUsage/ClaudeUsage`.
