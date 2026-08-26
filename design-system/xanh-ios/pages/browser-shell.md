# Browser shell overrides

These rules override `../MASTER.md` for iPhone and iPad browser chrome.

- Compact width: small identity rail at top, content, then a safe-area-aware
  bottom dock with navigation, omnibox and five top-level actions.
- Regular width: show Profile / Space / sync context without hiding the page;
  keep the same action hierarchy and keyboard shortcuts.
- Omnibox is the strongest control after the page. It uses a visible label for
  VoiceOver, 16pt-equivalent text and a separate 48pt Go target.
- Tab Grid must expose New Tab, open and close buttons in addition to swipe.
- Selected tabs use border + `ACTIVE`; private tabs use icon + `PRIVATE`.
- Privacy cover uses the centered Xanh arrow mark and contains no session snapshot.
- Dynamic Type accessibility sizes may stack the navigation and address rows;
  no control or focused field may be hidden behind the dock.
