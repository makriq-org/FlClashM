package com.follow.clashx.service

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RuntimeNodeResolverFileTest {

    private val placeholder = RuntimeNodeResolverFile.SYSTEM_DNS_PLACEHOLDER

    @Test
    fun `system dns is expanded where the node asked for it`() {
        assertEquals(
            "1.1.1.1\n8.8.8.8\n8.8.4.4\n9.9.9.9\n",
            RuntimeNodeResolverFileWriter.buildResolverList(
                "1.1.1.1\n$placeholder\n9.9.9.9\n",
                listOf("8.8.8.8", "8.8.4.4"),
            ),
        )
    }

    @Test
    fun `duplicates are dropped by address and the first port wins`() {
        assertEquals(
            "8.8.8.8:5353\n",
            RuntimeNodeResolverFileWriter.buildResolverList(
                "8.8.8.8:5353\n8.8.8.8\n",
                emptyList(),
            ),
        )
    }

    @Test
    fun `an earlier static entry beats a colliding system resolver`() {
        assertEquals(
            "8.8.8.8:5353\n",
            RuntimeNodeResolverFileWriter.buildResolverList(
                "8.8.8.8:5353\n$placeholder\n",
                listOf("8.8.8.8"),
            ),
        )
    }

    @Test
    fun `a system resolver listed first beats a later static duplicate`() {
        assertEquals(
            "8.8.8.8\n",
            RuntimeNodeResolverFileWriter.buildResolverList(
                "$placeholder\n8.8.8.8:5353\n",
                listOf("8.8.8.8"),
            ),
        )
    }

    @Test
    fun `comments and blank lines are dropped`() {
        assertEquals(
            "1.1.1.1\n",
            RuntimeNodeResolverFileWriter.buildResolverList(
                "# note\n\n1.1.1.1\n",
                emptyList(),
            ),
        )
    }

    @Test
    fun `a bare IPv6 literal is not mistaken for an address with a port`() {
        assertEquals(
            "2001:db8::1\n",
            RuntimeNodeResolverFileWriter.buildResolverList("2001:db8::1\n", emptyList()),
        )
    }

    @Test
    fun `a bracketed IPv6 address de-duplicates against its bare form`() {
        assertEquals(
            "[2001:db8::1]:5353\n",
            RuntimeNodeResolverFileWriter.buildResolverList(
                "[2001:db8::1]:5353\n2001:db8::1\n",
                emptyList(),
            ),
        )
    }

    @Test
    fun `a node depending only on unavailable system dns yields nothing`() {
        assertEquals(
            "",
            RuntimeNodeResolverFileWriter.buildResolverList("$placeholder\n", emptyList()),
        )
    }

    @Test
    fun `paths outside the node working directory are refused`() {
        val root = Files.createTempDirectory("runtime-node-resolver").toFile()
        try {
            assertNull(RuntimeNodeResolverFileWriter.resolveInside(root, "../escape.txt"))
            assertNull(RuntimeNodeResolverFileWriter.resolveInside(root, "nested/../../escape.txt"))
            assertNull(RuntimeNodeResolverFileWriter.resolveInside(root, "/etc/hosts"))
            assertNull(RuntimeNodeResolverFileWriter.resolveInside(root, "  "))
            assertTrue(
                RuntimeNodeResolverFileWriter
                    .resolveInside(root, "cache/fp1/logs")!!
                    .path
                    .startsWith(root.canonicalPath),
                "a nested relative path stays inside the node directory",
            )
            assertTrue(
                RuntimeNodeResolverFileWriter
                    .resolveInside(root, "client_resolvers.txt")!!
                    .path
                    .startsWith(root.canonicalPath),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `render reports whether the generated list actually changed`() {
        val root = Files.createTempDirectory("runtime-node-render").toFile()
        try {
            val spec = RuntimeNodeResolverFile(
                template = "client_resolvers.template",
                path = "client_resolvers.txt",
                dependsOnSystemDns = true,
                resetPaths = emptyList(),
            )
            File(root, spec.template).writeText("$placeholder\n1.1.1.1\n")

            assertEquals(
                RuntimeNodeResolverFileRenderResult.CHANGED,
                RuntimeNodeResolverFileWriter.render(root, spec, listOf("8.8.8.8")),
            )
            assertEquals("8.8.8.8\n1.1.1.1\n", File(root, spec.path).readText())

            assertEquals(
                RuntimeNodeResolverFileRenderResult.UNCHANGED,
                RuntimeNodeResolverFileWriter.render(root, spec, listOf("8.8.8.8")),
            )
            assertEquals(
                RuntimeNodeResolverFileRenderResult.CHANGED,
                RuntimeNodeResolverFileWriter.render(root, spec, listOf("9.9.9.9")),
            )
            assertEquals("9.9.9.9\n1.1.1.1\n", File(root, spec.path).readText())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `render fails instead of keeping a stale list`() {
        val root = Files.createTempDirectory("runtime-node-render-failure").toFile()
        try {
            val spec = RuntimeNodeResolverFile(
                template = "client_resolvers.template",
                path = "client_resolvers.txt",
                dependsOnSystemDns = true,
                resetPaths = emptyList(),
            )
            File(root, spec.path).writeText("stale\n")
            File(root, spec.template).writeText("$placeholder\n")

            // An empty system DNS list is reported apart from a broken
            // declaration, but it is still a refusal: the old list must survive
            // untouched either way.
            assertEquals(
                RuntimeNodeResolverFileRenderResult.SYSTEM_DNS_UNAVAILABLE,
                RuntimeNodeResolverFileWriter.render(root, spec, emptyList()),
            )
            assertEquals("stale\n", File(root, spec.path).readText())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `missing system dns is reported apart from a broken declaration`() {
        val root = Files.createTempDirectory("runtime-node-render-cause").toFile()
        try {
            val spec = RuntimeNodeResolverFile(
                template = "client_resolvers.template",
                path = "client_resolvers.txt",
                dependsOnSystemDns = true,
                resetPaths = emptyList(),
            )

            // No template at all: a declaration problem, not a network one.
            assertEquals(
                RuntimeNodeResolverFileRenderResult.FAILED,
                RuntimeNodeResolverFileWriter.render(root, spec, listOf("8.8.8.8")),
            )

            // A template that escapes the working directory is also a
            // declaration problem, whatever the system DNS looks like.
            assertEquals(
                RuntimeNodeResolverFileRenderResult.FAILED,
                RuntimeNodeResolverFileWriter.render(
                    root,
                    spec.copy(template = "../escape.template"),
                    emptyList(),
                ),
            )

            File(root, spec.template).writeText("$placeholder\n")
            assertEquals(
                RuntimeNodeResolverFileRenderResult.SYSTEM_DNS_UNAVAILABLE,
                RuntimeNodeResolverFileWriter.render(root, spec, emptyList()),
            )

            // A template that yields nothing *without* asking for system DNS is
            // a broken declaration, not an unavailable network.
            File(root, spec.template).writeText("# only a comment\n")
            assertEquals(
                RuntimeNodeResolverFileRenderResult.FAILED,
                RuntimeNodeResolverFileWriter.render(root, spec, emptyList()),
            )

            // The node still comes up when it declares resolvers of its own.
            File(root, spec.template).writeText("$placeholder\n1.1.1.1\n")
            assertEquals(
                RuntimeNodeResolverFileRenderResult.CHANGED,
                RuntimeNodeResolverFileWriter.render(root, spec, emptyList()),
            )
            assertEquals("1.1.1.1\n", File(root, spec.path).readText())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `a system resolver carrying an ipv6 zone is dropped`() {
        // Java hands back link-local addresses as `fe80::1%wlan0`. The zone is
        // not part of the resolver-file contract on either side, and the bare
        // address is unroutable, so the entry must not reach the file.
        assertEquals(
            listOf("8.8.8.8", "2001:db8::1"),
            SystemDnsReader.sanitize(
                listOf("8.8.8.8", "fe80::1%wlan0", "2001:db8::1", "fe80::abcd%rmnet0"),
            ),
        )
        assertEquals(emptyList(), SystemDnsReader.sanitize(listOf("fe80::1%wlan0")))
    }

    @Test
    fun `system dns entries are trimmed, de-duplicated and never blank`() {
        assertEquals(
            listOf("8.8.8.8", "1.1.1.1"),
            SystemDnsReader.sanitize(listOf(" 8.8.8.8 ", "", "1.1.1.1", "8.8.8.8", "   ")),
        )
    }

    @Test
    fun `a zoned system resolver never reaches the rendered list`() {
        val root = Files.createTempDirectory("runtime-node-zone").toFile()
        try {
            val spec = RuntimeNodeResolverFile(
                template = "client_resolvers.template",
                path = "client_resolvers.txt",
                dependsOnSystemDns = true,
                resetPaths = emptyList(),
            )
            File(root, spec.template).writeText("$placeholder\n")

            assertEquals(
                RuntimeNodeResolverFileRenderResult.CHANGED,
                RuntimeNodeResolverFileWriter.render(
                    root,
                    spec,
                    SystemDnsReader.sanitize(listOf("fe80::1%wlan0", "8.8.8.8")),
                ),
            )
            assertEquals("8.8.8.8\n", File(root, spec.path).readText())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `resolver-dependent state is reset only inside the node directory`() {
        val root = Files.createTempDirectory("runtime-node-reset").toFile()
        try {
            val cache = File(root, "cache/fp1").apply { mkdirs() }
            File(cache, "resolver.log").writeText("old")
            val spec = RuntimeNodeResolverFile(
                template = "client_resolvers.template",
                path = "client_resolvers.txt",
                dependsOnSystemDns = true,
                resetPaths = listOf("cache/fp1"),
            )

            assertTrue(RuntimeNodeResolverFileWriter.resetDeclaredPaths(root, spec))
            assertFalse(cache.exists())
            assertFalse(
                RuntimeNodeResolverFileWriter.resetDeclaredPaths(
                    root,
                    spec.copy(resetPaths = listOf(".")),
                ),
            )
        } finally {
            root.deleteRecursively()
        }
    }
}
