const allSourcesEnabled = bool.fromEnvironment(
  'ALL_SOURCES',
  defaultValue: true,
);
const appName = allSourcesEnabled ? '真果鉴' : '红果鉴';
const appSlug = allSourcesEnabled ? 'zhenguojian' : 'hongguojian';
