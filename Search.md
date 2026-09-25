# Search

Search is usually the fastest way to get anywhere in Launchy, faster than
paging or scanning the grid by eye once you know an app's name.

## The basic flow

Open Launchy and just start typing. The grid filters live as you type, with
a light debounce so it stays smooth even while you're mid-word. Press
`Return` to launch the top match, or use the arrow keys to move to a
different result before committing.

## It understands more than exact names

A few things make search forgiving instead of literal:

- **Bilingual matching.** Launchy searches both English and your system
  language at the same time, so whichever name you happen to remember for
  an app, English or localized, just works. You don't need to know which
  language an app "officially" uses.
- **Normalized matching.** Case and diacritics are folded out before
  comparing, so typing `"cafe"` still finds `"Café"`, and `"face"` still
  finds `"FaceTime"`. You don't have to get accents or capitalization
  exactly right.
- **Substring matching against names and bundle IDs.** You don't need to
  type from the start of an app's name; a fragment that appears anywhere in
  the name or its underlying bundle identifier is enough to surface it.

## When to use search vs. browsing

If you already know roughly what an app is called, search is almost always
quicker than paging to find it. Save browsing the grid for when you're not
sure what you're looking for yet, or when you're actively organizing
things, see [Organizing Your Apps](Organizing-Your-Apps) for that side of
things.

See also: [Getting Started](Getting-Started), [Keyboard Shortcuts](Keyboard-Shortcuts).
