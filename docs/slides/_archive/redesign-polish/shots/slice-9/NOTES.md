# Slice 9: themed pickers in form cards

Renders: `settings-` and `page-` levers, light and dark (bed daemon at 127.0.0.1:7911, front app never Schermes).

## Matches
- When idle sheet (`mac-page-when-idle-*.sheet.png`): From, Until, Model are label + bold value + chevron, as
  MacSettings draws its run rows. No pop-up bezel in light or dark.
- Plugins (`mac-settings-plugins-*.sheet.png`): "Test as  Mo" in the same style.
- Web search (`mac-settings-web-*.sheet.png`): Endpoint and Key fields now start at the same column.
- Agent settings page (`mac-settings-agent-*.png`): When idle card menus and the subtitle model menu unchanged in
  look, now through the shared `ValueMenu`.

## Differs
- Idle sheet "Daily budget" is still a wide bordered text field; MacSettings shows a bold plain value.
- Stepper (Model calls per pass) and switches stay native controls.
- Not rendered: server editor (Transport), Form for (select fields), New agent starting rules, the menus open.
