---
name: azdo-workitem
description: Read or post a comment to an Azure DevOps work item. Use when the user asks to view, update, or comment on an AzDo ticket/work item (e.g. "/azdo-workitem 1531365", "post progress to work item 1234", "what's the status of ticket 5678").
---

# /azdo-workitem — Read or comment on an Azure DevOps work item

Parse the user's input to extract a work item ID and intent (read vs. comment), then use the `az` CLI.

## Parsing

- **Work item ID**: numeric ID from the URL or natural language (e.g. `1531365` from `https://dev.azure.com/psgov/Cloud-PA/_workitems/edit/1531365`)
- **Org**: always `https://dev.azure.com/psgov`
- **Intent**: read/view → fetch and display; comment/update/post → add a discussion comment
- If the ID is missing, ask before running

## Reading a work item

```bash
az boards work-item show --id <ID> --org https://dev.azure.com/psgov --output json
```

Display: title, state, type, assigned-to, and the last few discussion comments.

To read comments specifically:
```bash
az boards work-item show --id <ID> --org https://dev.azure.com/psgov --query "fields" --output json
```

## Posting a comment

Use `az boards work-item update --discussion` with HTML for proper rendering in AzDo.
Plain text is displayed as a single unformatted block — always use HTML.

```bash
az boards work-item update \
  --id <ID> \
  --org https://dev.azure.com/psgov \
  --discussion "<HTML content>" \
  --output json
```

### HTML formatting reference

```html
<div>
  <b>Section heading</b><br><br>
  Introductory sentence.<br><br>

  <b>Sub-heading</b>
  <ul>
    <li>Bullet one</li>
    <li>Bullet two</li>
  </ul>
</div>
```

Supported tags: `<b>`, `<br>`, `<ul>`, `<li>`, `<a href="...">`, `<div>`.
Do NOT use `<h1>`–`<h3>`, `<p>`, or inline CSS styles — AzDo strips them.

## Editing an existing comment

The `az boards` and `az rest` CLIs do not have sufficient auth to PATCH an existing comment
(returns HTTP 401 with anonymous user). **Editing is not possible via CLI.**
Workaround: post a corrected replacement comment and ask the user to delete the old one from the UI.

## Examples

- `/azdo-workitem 1531365` → fetch and display the work item
- "post progress to work item 1531365" → draft HTML comment and post it
- "update ticket 1234 with today's deploy results" → draft HTML comment and post it

## Notes

- The `--discussion` flag always **adds** a new comment; it never edits an existing one.
- AzDo project for most CloudOps work items: `Cloud-PA`. Confirm if unsure.
- Work item URL pattern: `https://dev.azure.com/psgov/<project>/_workitems/edit/<ID>`
