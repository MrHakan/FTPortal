package com.mrhakan.ftportal

import java.net.Inet4Address
import java.net.NetworkInterface

object NetworkUrls {
    fun ipv4Addresses(): List<String> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .filter { it.isSiteLocalAddress }
            .map { it.hostAddress ?: "" }
            .filter { it.isNotBlank() }
            .distinct()
    }.getOrDefault(emptyList())

    fun urls(port: Int): List<String> = ipv4Addresses().map { "http://$it:$port" }
}
