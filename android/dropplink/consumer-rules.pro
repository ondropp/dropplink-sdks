# Keep the public API (spec section 2) so apps and the Flutter / React Native bridges that reach it
# reflectively or from other modules always find it. Internals may be shrunk and renamed freely.
-keep class app.ondropp.dropplink.Dropplink { public *; }
-keep class app.ondropp.dropplink.DropplinkConfig { public *; }
-keep class app.ondropp.dropplink.DeepLink { public *; }
-keep class app.ondropp.dropplink.Attribution { public *; }
-keep interface app.ondropp.dropplink.DeepLinkListener { *; }
-keep class app.ondropp.dropplink.Revenue { public *; }
