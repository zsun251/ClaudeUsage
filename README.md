# ClaudeUsage

A tiny macOS menu bar app that shows your Claude session and weekly usage, refreshing every 5 minutes and after wake.

It reads the Claude Code sign-in from the login keychain at runtime, read-only, so Claude Code must be signed in on this Mac. It never renews the token itself (that would log Claude Code out, since the refresh token rotates); after it expires (~8h) the menu shows "stale" until you next use `claude`. No credentials are stored in this repo.

## Build

```sh
swiftc -O main.swift -o ~/Applications/ClaudeUsage
```

## Run at login

```sh
cp com.user.claudeusage.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.claudeusage.plist
```

The source stays in this repo; the built app goes to `~/Applications/ClaudeUsage`. Edit the path inside the plist if it is elsewhere.
