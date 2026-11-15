package com.follow.clashx.common

/** Main thread only. A replaced launch must not answer the newer; reset once the activity is gone. */
class RequestCodes(private val first: Int, private val count: Int) {
    private var next = 0
    private var current: Int? = null
    private val unanswered = mutableSetOf<Int>()

    fun issue(): Int? {
        val code = (0 until count)
            .map { first + (next + it) % count }
            .firstOrNull { it !in unanswered }
            ?: return null
        next = (code - first + 1) % count
        unanswered += code
        current = code
        return code
    }

    operator fun contains(code: Int): Boolean = code in first until first + count

    fun answers(code: Int): Boolean {
        // This launch can never answer twice, even if its answer is stale.
        unanswered -= code
        // A replaced launch keeps answering until reset, but its answer is stale.
        if (code != current) {
            return false
        }
        // Every older launch was replaced too, so none of them can still answer.
        unanswered.clear()
        current = null
        return true
    }

    fun reset() {
        unanswered.clear()
        current = null
    }
}
