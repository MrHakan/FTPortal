package com.mrhakan.ftportal

import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

/** Rejects public/VPN HTTP clients while keeping loopback and active LAN/AP subnets usable. */
object LocalNetworkGuard {
    private val ignoredAdapterMarkers = listOf(
        "vpn", "tun", "tap", "wireguard", "tailscale", "zerotier", "hamachi"
    )

    fun isAllowed(remote: String): Boolean {
        if (remote.isBlank()) return true
        val address = runCatching { InetAddress.getByName(remote) }.getOrNull() ?: return false
        if (address.isLoopbackAddress) return true
        val client = address as? Inet4Address ?: return false
        if (!client.isSiteLocalAddress) return false

        return runCatching {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback && !isIgnored(it) }
                .flatMap { it.interfaceAddresses }
                .mapNotNull { binding ->
                    val local = binding.address as? Inet4Address ?: return@mapNotNull null
                    val prefix = binding.networkPrefixLength.toInt()
                    if (prefix !in 1..32) return@mapNotNull null
                    local to prefix
                }
                .any { (local, prefix) -> sameSubnet(local, client, prefix) }
        }.getOrDefault(false)
    }

    private fun isIgnored(networkInterface: NetworkInterface): Boolean {
        val label = "${networkInterface.name} ${networkInterface.displayName}".lowercase()
        return ignoredAdapterMarkers.any { label.contains(it) }
    }

    private fun sameSubnet(left: Inet4Address, right: Inet4Address, prefix: Int): Boolean {
        val leftBytes = left.address
        val rightBytes = right.address
        val fullBytes = prefix / 8
        val remainingBits = prefix % 8
        for (index in 0 until fullBytes) {
            if (leftBytes[index] != rightBytes[index]) return false
        }
        if (remainingBits == 0 || fullBytes >= 4) return true
        val mask = (0xff shl (8 - remainingBits)) and 0xff
        return (leftBytes[fullBytes].toInt() and mask) == (rightBytes[fullBytes].toInt() and mask)
    }
}
