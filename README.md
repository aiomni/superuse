<p align="center">
  <img src="Resources/AppIcon-v2/superuse.png" width="112" height="112" alt="superuse toolbox icon">
</p>

# superuse

A small toolbox in your Mac's menu bar. Capture and annotate screenshots, save long pages, and find the text or image you copied earlier.

**Requires macOS 26 or later.** The app's interface is currently in Simplified Chinese.

## What you can do

- **Capture a screen, window, or region.** Select a window with a click or drag around exactly what you need.
- **Annotate before sharing.** Add arrows, shapes, text, freehand marks, mosaics, and opaque redactions, with undo and redo.
- **Capture a long page.** Scroll through the content yourself while superuse combines it into one image.
- **Find your clipboard history.** Search copied text and images, edit text, and copy or paste an earlier entry.
- **Make it fit your workflow.** Customize shortcuts, pause clipboard recording, and choose whether to launch at login.

## Getting started

Open superuse and use its toolbox or menu bar icon to choose an action. Closing the toolbox keeps the app available in the menu bar; use Quit to exit.

| Shortcut | Action |
| --- | --- |
| Control + Option + Space | Open the toolbox |
| Shift + Command + A | Start a screenshot |
| Control + Option + V | Show or hide clipboard history |

Change shortcuts in Settings → Shortcuts. Press Delete while recording a shortcut to disable it, or Esc to cancel. Conflicting shortcuts are reported in settings.

To start superuse when you sign in, enable Launch at Login in Settings → General. It will stay in the menu bar without opening the toolbox.

For building the app from source, see the [development guide](DEV.md).

## Screenshots

1. Press **Shift + Command + A** to freeze the screen. Move over a window to select it, or over the desktop to select the screen.
2. **Click** to confirm, or **drag** to select an area.
3. Annotation tools are ready immediately. Draw on the image, start a scrolling capture, change the selection, save, or copy.
4. Press **Return** to copy and finish, **Shift + Command + C** to copy and keep editing, **Command + S** to save, or **Esc** to cancel.

While annotating, use **Command + Z** to undo and **Shift + Command + Z** to redo. **Esc** exits the screenshot even while the canvas or an editing control has focus. In a text-entry or save dialog, the dialog handles its own keyboard shortcuts.

Choose **Mosaic (打码)**, the checkerboard icon, and drag over an area to pixelate it. The fine, medium, and coarse controls set the block size for the next area. **Redact (遮挡)** covers an area with opaque black. Both tools are included in copied and saved images and support undo and redo.

By default, confirming a selection also copies the original screenshot. Turn off automatic copying in screenshot settings if you prefer to edit first.

Screenshots work across multiple-monitor setups, with each selection staying on one display. Window captures include the visible part of the window, without its shadow.

### Scrolling screenshots

Select the content area and choose the scrolling action before adding annotations. Adding an annotation disables scrolling capture; undo or clear all annotations to enable it again. Choosing a tool, color, or line width does not disable it. Scroll downward slowly, keeping some of the previous content visible each time. Click Finish or press **Shift + Command + A** again to return to the preview.

Keep fixed headers and sidebars outside the selection where possible. Animation, repeated patterns, fast scrolling, and scrolling backward can interrupt matching. If that happens, superuse keeps the portion already captured so you can retry or save it.

## Clipboard history

Open clipboard history and start typing to search. Use the keyboard or double-click an entry to reuse it.

| Key or action | Result |
| --- | --- |
| Up / Down | Select an entry |
| Return or double-click | Copy the entry and close the panel |
| Command + Return | Paste into the app you were using before opening history |
| Command + E | Edit a text entry |
| Command + Delete | Delete an entry |
| Command + F | Focus search |
| Esc | Close the panel |

superuse keeps the latest **100 entries** by default. Choose 50, 100, or 200 in settings. Copying the same content again moves it to the top.

History supports text and images. Rich-text formatting and file attachments are not preserved. You can pause recording, exclude specific apps, or clear your history at any time.

## Permissions and privacy

superuse works locally on your Mac and does not require an account.

| Permission | Why it is needed |
| --- | --- |
| Screen recording | To capture your screen when you start a screenshot |
| Clipboard access | To record the text and images you copy |
| Accessibility | To paste directly into another app |
| Login items | To open automatically at login, if you enable that option |

Settings includes shortcuts to the relevant system settings. Without Accessibility permission, you can still copy an entry and paste it yourself. If direct paste cannot return to the target app, the entry remains copied for manual pasting.

Clipboard history is kept only for the current session by default. Enable persistence in settings to keep it after restarting the app. Turning persistence off deletes the saved copy while keeping the current session's history available. Saved history is not encrypted by superuse.

> [!NOTE]
> superuse skips content marked sensitive by the source app by default, but it cannot recognize every password or secret. Pause recording or exclude an app when working with sensitive information.

## Help

- **Screenshots are unavailable:** allow screen recording in System Settings, then restart superuse if prompted.
- **Clipboard history is empty:** check that recording is enabled and macOS allows clipboard access.
- **Direct paste does not work:** allow Accessibility access, or copy the entry and paste manually.
- **Launch at login needs approval:** use the settings shortcut to review login items in System Settings.

For a bug or feature request, [open an issue](https://github.com/aiomni/superuse/issues). Remove private text, images, and personal details from anything you share.
