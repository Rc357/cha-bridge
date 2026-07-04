enum AppFlavor {
  development('DEVELOPMENT', 'DEV '),
  staging('STAGING', 'STG '),
  production('PRODUCTION', '');

  const AppFlavor(this.description, this.titlePrefix);

  final String description;
  final String titlePrefix;
}
