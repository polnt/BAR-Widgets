# How to Contribute a New Widget

There are **two ways** to contribute:

1. **Direct Contribution:**
  - Add your widget directly to this repository under `Widgets/community/<your_widget_id>` (simplest) by forking this repository. Create and maintain your widgets in your fork, and make a pull request to the main repository to update your widget in the hub.

2. **External Repository:**
  - Maintain your own repository and link it to this repository by adding a git submodule.
    - Fork this repository and add a git submodule to your own repository, then create a PR to add your submodule to the hub.
    - **Note:** If you have multiple widgets in the same repository, *each update* will require *all* widgets to be approved at the same time, which can slow down the process.


# Required Widget Structure

```
<your_widget_id>/
  ├─ <your_widget_id>.lua   # Main widget code
  ├─ cover.png              # PNG image (~400x400) showcasing your widget
  ├─ README.md              # Detailed explanation of your widget
  ├─ manifest.json          # Technical data about your widget (see below)
  └─ <other_files_allowed_up_to_a_point> # You are not limited to a single file, but try to keep it within reason
```


The widget directory name is the widget ID. It must be globally unique, lower snake case, and include a scope prefix such as `gui_`, `cmd_`, `unit_`, or `map_`. The `id` in `manifest.json` must match this directory name exactly, for example `gui_lower_snake_case`.

Each widget directory must stay under 5 MiB.



## manifest.json

Ensure your `id` is globally unique, has a scope prefix, and matches the root directory of the widget. Avoid using common or generic IDs.

Your `manifest.json` must include the following fields:

```json
{
  "id": "<your_widget_id>",
  "version": "1.0.0",
  "display_name": "A Pretty Display Name",
  "author": "YourUserName",
  "discord_link": "https://discord.com/channels/12345/12345",
  "github_link": "https://github.com/beyond-all-reason/Beyond-All-Reason/pull/5309",
  "description": "A SHORT description that summarizes your widget.",
  "last_updated": "2026-01-01T00:00:00.000Z"
}
```

The `last_updated` field is an ISO 8601 timestamp used to sort widgets by recency. Update it whenever you publish a new version.

The merged catalog is validated during the build against [builder/schemas/manifests.schema.json](builder/schemas/manifests.schema.json). The same schema is copied into the generated `build/` output as `manifests.schema.json`.

# License

This repository is licensed under the GNU General Public License, version 2 or later. See [LICENSE](LICENSE) for details.

# What is Allowed?

Currently, all widgets are manually vetted and moderated by a group of contributors. Widgets that are clear violations of the Game Design Document will be rejected. Please do not engage in discussion about moderation in this repository. Instead, use the appropriate channels on the BAR Discord server.
