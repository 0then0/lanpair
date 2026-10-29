package org.lanpair.lanpair

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface
import java.util.Collections

/** No location data, subnet scan, background service, or firewall changes. */
class LanPairPlatform(private val activity: Activity, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val nsd = requireNotNull(activity.getSystemService(NsdManager::class.java))
    private val connectivity = requireNotNull(activity.getSystemService(ConnectivityManager::class.java))
    private var sink: EventChannel.EventSink? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var browser: NsdManager.DiscoveryListener? = null
    private var multicast: WifiManager.MulticastLock? = null
    private var discoveryMulticast: WifiManager.MulticastLock? = null
    private var activeResolution: NsdManager.ResolveListener? = null
    private var permissionReply: MethodChannel.Result? = null
    private var generation = 0
    private var activeSession = ""
    private var activeDevice = ""
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private val resolved = mutableSetOf<String>()
    private var resolving = false
    private val changes = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = event(mapOf("type" to "networkChanged"))
        override fun onLost(network: Network) = event(mapOf("type" to "networkChanged"))
        override fun onLinkPropertiesChanged(network: Network, properties: android.net.LinkProperties) =
            event(mapOf("type" to "networkChanged"))
    }

    init {
        EventChannel(messenger, "lanpair/discovery").setStreamHandler(this)
        MethodChannel(messenger, "lanpair/platform").setMethodCallHandler { call, reply ->
            try {
                when (call.method) {
                    "capabilities" -> reply.success(capabilities())
                    "requestPermission" -> requestPermission(reply)
                    "openSettings" -> {
                        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.parse("package:${activity.packageName}")))
                        reply.success(null)
                    }
                    "acquireMulticast" -> {
                        if (multicast == null) {
                            val wifi = requireNotNull(activity.applicationContext.getSystemService(WifiManager::class.java))
                            multicast = wifi.createMulticastLock("LANPair bounded diagnostic").apply {
                                setReferenceCounted(false)
                                acquire()
                            }
                        }
                        reply.success(null)
                    }
                    "releaseMulticast" -> { releaseMulticast(); reply.success(null) }
                    "startDiscovery" -> {
                        @Suppress("UNCHECKED_CAST")
                        try { startDiscovery(call.arguments as Map<String, Any?>) }
                        catch (error: Exception) { stopDiscovery(); throw error }
                        reply.success(null)
                    }
                    "stopDiscovery" -> { stopDiscovery(); reply.success(null) }
                    else -> reply.notImplemented()
                }
            } catch (error: SecurityException) {
                reply.error("permission_denied", "Local network permission was denied.", null)
            } catch (error: Exception) {
                // Return stable codes; raw exception messages can disclose addresses.
                reply.error("platform_error", error.javaClass.simpleName, null)
            }
        }
        if (Build.VERSION.SDK_INT >= 24) connectivity.registerDefaultNetworkCallback(changes)
        else connectivity.registerNetworkCallback(NetworkRequest.Builder().build(), changes)
    }

    private fun runtimePermission(): String? = when {
        Build.VERSION.SDK_INT >= 37 && activity.applicationInfo.targetSdkVersion >= 37 ->
            "android.permission.ACCESS_LOCAL_NETWORK"
        // Android 16's opt-in protections use this permission. Request only on API 36.
        Build.VERSION.SDK_INT == 36 -> "android.permission.NEARBY_WIFI_DEVICES"
        else -> null
    }

    private fun capabilities(): Map<String, Any> {
        val required = runtimePermission()
        val permission = if (required == null) "notRequired" else if (
            activity.checkSelfPermission(required) == PackageManager.PERMISSION_GRANTED) "granted"
            else if (Build.VERSION.SDK_INT == 36) "unknown" else "denied"
        return mapOf("platform" to "android", "osVersion" to Build.VERSION.RELEASE,
            "permission" to permission, "rawMulticast" to true, "discovery" to true,
            "limitationCodes" to if (Build.VERSION.SDK_INT < 33)
                listOf("discovery_interface_system_selected") else emptyList<String>(),
            "interfaces" to Collections.list(NetworkInterface.getNetworkInterfaces()).filter { it.isUp }.map { item ->
                mapOf("name" to item.name, "index" to item.index,
                    "addresses" to Collections.list(item.inetAddresses).mapNotNull { it.hostAddress })
            })
    }

    private fun requestPermission(reply: MethodChannel.Result) {
        val required = runtimePermission()
        if (required == null || activity.checkSelfPermission(required) == PackageManager.PERMISSION_GRANTED) {
            reply.success(capabilities()); return
        }
        if (permissionReply != null) { reply.error("permission_busy", "A permission request is pending.", null); return }
        permissionReply = reply
        activity.requestPermissions(arrayOf(required), PERMISSION_REQUEST)
    }

    fun onRequestPermissionsResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        permissionReply?.success(capabilities()); permissionReply = null
        event(mapOf("type" to "permission", "permission" to capabilities()["permission"]!!))
    }

    fun onResume() = event(mapOf("type" to "permission", "permission" to capabilities()["permission"]!!))

    private fun event(value: Map<String, Any>) {
        main.post { sink?.success(value) }
    }

    @Suppress("DEPRECATION")
    private fun startDiscovery(args: Map<String, Any?>) {
        stopDiscovery()
        activeSession = args["sessionId"] as String
        activeDevice = args["deviceId"] as String
        require(activeSession.length in 1..128 && activeDevice.length in 1..128)
        val port = (args["port"] as Number).toInt(); require(port in 1..65535)
        val index = (args["interfaceIndex"] as? Number)?.toInt() ?: 0
        val selected = if (index > 0 && Build.VERSION.SDK_INT >= 33) {
            val interfaceName = NetworkInterface.getByIndex(index)?.name
            connectivity.allNetworks.firstOrNull { connectivity.getLinkProperties(it)?.interfaceName == interfaceName }
                ?: throw IllegalArgumentException("interface_unavailable")
        } else null
        val token = generation
        if (Build.VERSION.SDK_INT < 34) {
            val wifi = requireNotNull(activity.applicationContext.getSystemService(WifiManager::class.java))
            discoveryMulticast = wifi.createMulticastLock("LANPair bounded DNS-SD").apply {
                setReferenceCounted(false); acquire()
            }
        }
        val info = NsdServiceInfo().apply {
            serviceName = "LP-${activeSession.take(16)}-${activeDevice.take(16)}"
            serviceType = "_lanpair._tcp."
            this.port = port
            setAttribute("session", activeSession)
            setAttribute("device", activeDevice)
            if (Build.VERSION.SDK_INT >= 33) network = selected
        }
        registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(service: NsdServiceInfo) {
                if (token == generation) event(mapOf("type" to "published", "name" to service.serviceName))
            }
            override fun onRegistrationFailed(service: NsdServiceInfo, code: Int) {
                if (token == generation) event(mapOf("type" to "error", "code" to "dns_sd_publish", "nativeCode" to code))
            }
            override fun onServiceUnregistered(service: NsdServiceInfo) {}
            override fun onUnregistrationFailed(service: NsdServiceInfo, code: Int) {}
        }.also { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, it) }
        browser = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) {
                if (token == generation) event(mapOf("type" to "error", "code" to "dns_sd_browse", "nativeCode" to code))
            }
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onServiceLost(service: NsdServiceInfo) {
                if (token == generation) event(mapOf("type" to "removed", "name" to service.serviceName))
            }
            override fun onServiceFound(service: NsdServiceInfo) {
                main.post {
                    if (token != generation || !service.serviceName.startsWith("LP-${activeSession.take(16)}-") ||
                        service.serviceName == info.serviceName || resolved.size >= 8 || !resolved.add(service.serviceName)) return@post
                    resolveQueue.add(service); resolveNext(token)
                }
            }
        }.also {
            if (Build.VERSION.SDK_INT >= 33) nsd.discoverServices("_lanpair._tcp.", NsdManager.PROTOCOL_DNS_SD,
                selected, activity.mainExecutor, it)
            else nsd.discoverServices("_lanpair._tcp.", NsdManager.PROTOCOL_DNS_SD, it)
        }
    }

    @Suppress("DEPRECATION")
    private fun resolveNext(token: Int) {
        if (resolving || resolveQueue.isEmpty() || token != generation) return
        resolving = true
        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(service: NsdServiceInfo, code: Int) {
                main.post {
                    if (token != generation) return@post
                    activeResolution = null
                    resolving = false
                    event(mapOf("type" to "error", "code" to "dns_sd_resolve", "nativeCode" to code)); resolveNext(token)
                }
            }
            override fun onServiceResolved(service: NsdServiceInfo) {
                main.post {
                    if (token != generation) return@post
                    activeResolution = null
                    resolving = false
                    val session = service.attributes["session"]?.toString(Charsets.UTF_8)
                    val device = service.attributes["device"]?.toString(Charsets.UTF_8)
                    if (session == activeSession && device != null && device != activeDevice) {
                        val addresses = if (Build.VERSION.SDK_INT >= 34) service.hostAddresses.mapNotNull { it.hostAddress }
                            else listOfNotNull(service.host?.hostAddress)
                        event(mapOf("type" to "resolved", "name" to service.serviceName,
                            "host" to (service.host?.hostAddress ?: ""), "addresses" to addresses,
                            "port" to service.port, "sessionId" to session, "deviceId" to device))
                    }
                    resolveNext(token)
                }
            }
        }
        activeResolution = listener
        nsd.resolveService(resolveQueue.removeFirst(), listener)
    }

    @Suppress("DEPRECATION")
    fun stopDiscovery() {
        generation++; resolveQueue.clear(); resolved.clear(); resolving = false
        registration?.let { try { nsd.unregisterService(it) } catch (_: RuntimeException) {} }
        browser?.let { try { nsd.stopServiceDiscovery(it) } catch (_: RuntimeException) {} }
        if (Build.VERSION.SDK_INT >= 34) activeResolution?.let {
            try { nsd.stopServiceResolution(it) } catch (_: RuntimeException) {}
        }
        activeResolution = null
        discoveryMulticast?.let { if (it.isHeld) it.release() }; discoveryMulticast = null
        registration = null; browser = null
    }

    private fun releaseMulticast() { multicast?.let { if (it.isHeld) it.release() }; multicast = null }
    fun onStop() { stopDiscovery(); releaseMulticast() }
    fun dispose() {
        onStop(); connectivity.unregisterNetworkCallback(changes)
        permissionReply?.error("cancelled", "The activity was destroyed.", null); permissionReply = null
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }
    companion object { private const val PERMISSION_REQUEST = 7041 }
}
