/*
 * Copyright (c) 2021, TU Dresden.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

package org.lflang.util;

import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * Utilities to manipulate strings.
 *
 * @author Clément Fournier
 */
public final class StringUtil {

    /**
     * Matches the boundary of a camel-case word. That's a zero-length match.
     */
    private static final Pattern CAMEL_WORD_BOUNDARY =
        Pattern.compile("(?<![A-Z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])");

    private StringUtil() {
        // utility class
    }

    /**
     * Convert a string in Camel case to snake case. E.g.
     * `MinimalReactor` will be converted to `minimal_reactor`.
     * The string is assumed to be a single camel case identifier
     * (no whitespace).
     */
    public static String camelToSnakeCase(String str) {
        return CAMEL_WORD_BOUNDARY.splitAsStream(str)
                                  .filter(it -> !it.isEmpty())
                                  .map(it -> it.toLowerCase(Locale.ROOT))
                                  .collect(Collectors.joining("_"));
    }

    /**
     * If the given string is surrounded by single or double
     * quotes, returns what's inside the quotes. Otherwise
     * returns the same string.
     *
     * <p>Returns null if the parameter is null.
     */
    public static String removeQuotes(String str) {
        if (str == null) {
            return null;
        }
        if (str.length() < 2) {
            return str;
        }
        if (str.startsWith("\"") && str.endsWith("\"")
            || str.startsWith("'") && str.endsWith("'")) {
            return str.substring(1, str.length() - 1);
        }
        return str;
    }
    
    /**
     * Intelligently trim the white space in a code block.
	 * 
	 * The leading whitespaces of the first non-empty
	 * code line is considered as a common prefix across all code lines. If the
	 * remaining code lines indeed start with this prefix, it removes the prefix
	 * from the code line.
	 * 
     * For examples, this code
     * <pre>{@code 
     *        int test = 4;
     *        if (test == 42) {
     *            printf("Hello\n");
     *        }
     * }</pre>
     * will be trimmed to this:
     * <pre>{@code 
     * int test = 4;
     * if (test == 42) {
     *     printf("Hello\n");
     * }
     * }</pre>
     * 
     * The very first line of the given code is treated specially. Typically, it
     * should be blank, but it contains code if code is placed on the same line
     * as the opening {= symbol. That line is not used to determine the
     * whitespace prefix.
     * 
     * @param code the code block to be trimmed
     * @return trimmed code block 
     */
    public static String trimCodeBlock(String code) {
        String[] codeLines = code.split("(\r\n?)|\n");
        String prefix = getWhitespacePrefix(code);
        StringBuilder buffer = new StringBuilder();
        boolean stillProcessingLeadingBlankLines = true;
        for (String line : codeLines) {
            if (!line.isBlank()) stillProcessingLeadingBlankLines = false;
            if (stillProcessingLeadingBlankLines) continue;
            if (line.startsWith(prefix)) buffer.append(line.substring(prefix.length()));
            else buffer.append(line);
            buffer.append("\n");
        }
        return buffer.toString().strip();
    }

    private static String getWhitespacePrefix(String code) {
        String[] codeLines = code.split("(\r\n?)|\n");
        for (int j = 1; j < codeLines.length; j++) {
            String line = codeLines[j];
            for (var i = 0; i < line.length(); i++) {
                if (!Character.isWhitespace(line.charAt(i))) {
                    return line.substring(0, i);
                }
            }
        }
        return "";
    }

    public static String addDoubleQuotes(String str) {
        return "\""+str+"\"";
    }

    public static <T> String joinObjects(List<T> things, String delimiter) {
        return things.stream().map(T::toString).collect(Collectors.joining(delimiter));
    }
}
