package com.mrhakan.ftportal

import java.net.Inet4Address
import java.net.NetworkInterface

object NetworkUrls {
    fun ipv4Addresses(): List<String> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { network ->
                val label = "${network.name} ${network.displayName}".lowercase()
                network.isUp && !network.isLoopback &&
                    listOf("vpn", "tun", "tap", "wireguard", "tailscale", "zerotier", "hamachi")
                        .none { label.contains(it) }
            }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .filter { it.isSiteLocalAddress }
            .map { it.hostAddress ?: "" }
            .filter { it.isNotBlank() }
            .distinct()
    }.getOrDefault(emptyList())

    fun urls(port: Int): List<String> = ipv4Addresses().map { address ->
        if (port == 80) "http://$address" else "http://$address:$port"
    }
}
