package dev.zcode.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NtfyTest {

    @Test
    fun parse_message_event() {
        val line = """
            {"id":"uIdwd6oiZArv","time":1790134582,"expires":1790177782,"event":"message","topic":"zcode-abc123","title":"MacBook-Pro · zcode-app","message":"完成:修复了推送插件注册三件套","tags":["white_check_mark"]}
        """.trimIndent()
        val e = Ntfy.parse(line)!!
        assertEquals("message", e.event)
        assertEquals("zcode-abc123", e.topic)
        assertEquals("MacBook-Pro · zcode-app", e.title)
        assertEquals("完成:修复了推送插件注册三件套", e.message)
    }

    @Test
    fun parse_message_without_copy_falls_back_to_blank() {
        val e = Ntfy.parse("""{"event":"message","topic":"zcode-abc123"}""")!!
        assertEquals("", e.title)
        assertEquals("", e.message)
    }

    @Test
    fun parse_keepalive_has_event() {
        val e = Ntfy.parse("""{"id":"","time":1790134582,"expires":0,"event":"keepalive","topic":"zcode-abc123"}""")!!
        assertEquals("keepalive", e.event)
    }

    @Test
    fun parse_malformed_returns_null() {
        assertNull(Ntfy.parse("not json"))
        assertNull(Ntfy.parse("{\"no_event\":1}"))
        assertNull(Ntfy.parse(""))
    }

    @Test
    fun topic_validation() {
        assertTrue(Ntfy.isValidTopic("zcode-abc123"))
        assertTrue(Ntfy.isValidTopic("a"))
        assertTrue(Ntfy.isValidTopic("A_b-c"))
        assertFalse(Ntfy.isValidTopic(""))
        assertFalse(Ntfy.isValidTopic("有空格 topic"))
        assertFalse(Ntfy.isValidTopic("中文"))
        assertFalse(Ntfy.isValidTopic("a".repeat(65)))
    }

    @Test
    fun random_topic_shape() {
        val t = Ntfy.randomTopic()
        assertTrue(t.startsWith("zcode-"))
        assertTrue(Ntfy.isValidTopic(t))
        assertFalse(t == Ntfy.randomTopic())
    }
}
