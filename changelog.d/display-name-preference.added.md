- Display name preference: users can set a "Name" that outgoing mail carries
  in the From header (`"Chris Carr" <address>`). The name is stored in the
  user-preferences table and applied server-side by the `/send` Lambda, so it
  follows the user across the React and Apple clients; it is edited from the
  React account menu and the Apple Settings Composing section.
