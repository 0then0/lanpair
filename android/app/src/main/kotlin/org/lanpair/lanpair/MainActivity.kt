package org.lanpair.lanpair

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var platform: LanPairPlatform? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        platform = LanPairPlatform(this, flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        platform?.onRequestPermissionsResult(requestCode)
    }
    override fun onResume() { super.onResume(); platform?.onResume() }
    override fun onStop() { platform?.onStop(); super.onStop() }
    override fun onDestroy() { platform?.dispose(); platform = null; super.onDestroy() }
}
