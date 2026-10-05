- Apple: **Shared app code moved into one module.** The iPhone, iPad,
  Vision Pro and Mac apps now build their shared screens, view models and
  app state from a single `CabalmailUI` module, sorted into folders by
  feature, instead of each app compiling the same loose source files.
  Nothing should look or behave differently; anything that does is a bug
  worth reporting.
