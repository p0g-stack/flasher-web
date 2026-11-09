{{flutter_js}}
{{flutter_build_config}}

// Flutter's service worker is a self-unregistering stub; app_sw.js is
// registered from index.html instead, so no serviceWorkerSettings are passed.
// CanvasKit is served from this origin (build/web/canvaskit) so the app shell
// works offline and never depends on the gstatic CDN at runtime.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
  },
});
