# Document viewer sample

The in-app markdown viewer (`MarkdownDocumentContent` → `MarkdownDocumentHTML`) shares
one parser with chat, so the AST rewrite lands on both surfaces at once. This file
targets the part that is *only* the viewer: the `joiningListContinuations` pre-pass,
which the rewrite deletes.

Open this from a `github.com/.../blob/...` link — `MarkdownDocument.fetchURL` rewrites
it to raw and opens it in-app.

## What the pre-pass used to do

It glued an unmarked line onto the list item above it, because the old scanner accepted
only a contiguous run of marked list lines. The AST parses lazy continuations natively,
so the pre-pass is gone. Everything in this section must survive its removal.

### Lazy continuation, unindented

- this item wraps onto
a second line with no indent at all
- second item

### Lazy continuation, indented

- this item wraps onto
  an indented second line
- second item

### Ordered list, lazy continuation

1. first item that wraps onto
a second line
2. second item

### What the pre-pass wrongly swallowed

`isListContinuation` excluded headings, fences, thematic breaks and tables — but never
`>`. So a quote on the line after a list item was absorbed into the item. All four of
these must now stand as their own blocks:

- a list item
> a quote right after it

- a list item
# a heading right after it

- a list item
| a | table |
| --- | --- |
| 1 | 2 |

- a list item
---

### Multi-paragraph list items

The pre-pass handled only the no-blank-line case and left these as separate blocks.
The AST makes them real list items:

1. first item

   second paragraph of the first item

2. second item

   ```swift
   let insideAListItem = true
   ```

3. third item

### Nesting that needed the blank-line case

- level one
  - level two
    - level three

      a paragraph belonging to level three

  - back to level two
- back to level one

## Everything else the viewer draws

### A long document heading structure

#### h4
##### h5
###### h6

### Quote holding blocks

> ### Heading in a quote
>
> - a list in a quote
> - second item
>
> ```json
> { "inside": "a quote" }
> ```

### Table with alignment

| Left | Centre | Right |
| :--- | :----: | ----: |
| a | b | c |
| a much longer cell that has to wrap | x | 1,234 |

### Raw HTML

`MarkdownDocumentHTML.swift:263` escapes raw HTML on purpose, so all of this should
read as literal text rather than render. That is the current, deliberate behaviour —
flag it only if it changed.

<kbd>⌘</kbd> + <kbd>K</kbd>

<details>
<summary>A disclosure</summary>
Hidden body.
</details>

### Fragment links

- [Jump to the multi-paragraph section](#multi-paragraph-list-items)
- [Jump to the top](#document-viewer-sample)

---

End of document.
