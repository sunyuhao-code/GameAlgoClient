package com.gamealgo.sdk;

import java.lang.reflect.Array;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

final class GameAlgoJson {
    private GameAlgoJson() {}

    static Object parse(String input) throws GameAlgoException {
        Parser parser = new Parser(input);
        Object value = parser.parseValue();
        parser.skipWhitespace();
        if (!parser.isAtEnd()) {
            throw new GameAlgoException("Invalid JSON: trailing content");
        }
        return value;
    }

    static String stringify(Object value) throws GameAlgoException {
        StringBuilder builder = new StringBuilder();
        write(value, builder);
        return builder.toString();
    }

    @SuppressWarnings("unchecked")
    static Object readPath(Object source, String path) {
        if (path == null || path.length() == 0) {
            return source;
        }

        Object current = source;
        for (String segment : path.split("\\.")) {
            if (current instanceof Map) {
                current = ((Map<String, Object>) current).get(segment);
            } else if (current instanceof List) {
                try {
                    current = ((List<Object>) current).get(Integer.parseInt(segment));
                } catch (NumberFormatException | IndexOutOfBoundsException error) {
                    return null;
                }
            } else {
                return null;
            }

            if (current == null) {
                return null;
            }
        }
        return current;
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> asObject(Object value, String fieldName) throws GameAlgoException {
        if (value instanceof Map) {
            return (Map<String, Object>) value;
        }
        throw new GameAlgoException("Expected JSON object for " + fieldName);
    }

    @SuppressWarnings("unchecked")
    static List<Object> asArray(Object value, String fieldName) throws GameAlgoException {
        if (value instanceof List) {
            return (List<Object>) value;
        }
        throw new GameAlgoException("Expected JSON array for " + fieldName);
    }

    static String stringValue(Map<String, Object> object, String key, boolean required) throws GameAlgoException {
        Object value = object.get(key);
        if (value == null) {
            if (required) {
                throw new GameAlgoException("Missing required field: " + key);
            }
            return null;
        }
        if (value instanceof String) {
            return (String) value;
        }
        throw new GameAlgoException("Expected string field: " + key);
    }

    static int intValue(Map<String, Object> object, String key, boolean required) throws GameAlgoException {
        Object value = object.get(key);
        if (value == null) {
            if (required) {
                throw new GameAlgoException("Missing required field: " + key);
            }
            return 0;
        }
        if (value instanceof Number) {
            return ((Number) value).intValue();
        }
        throw new GameAlgoException("Expected number field: " + key);
    }

    static boolean boolValue(Map<String, Object> object, String key, boolean defaultValue) throws GameAlgoException {
        Object value = object.get(key);
        if (value == null) {
            return defaultValue;
        }
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        throw new GameAlgoException("Expected boolean field: " + key);
    }

    private static void write(Object value, StringBuilder builder) throws GameAlgoException {
        if (value == null) {
            builder.append("null");
        } else if (value instanceof String) {
            writeString((String) value, builder);
        } else if (value instanceof Number) {
            Number number = (Number) value;
            double doubleValue = number.doubleValue();
            if (Double.isNaN(doubleValue) || Double.isInfinite(doubleValue)) {
                throw new GameAlgoException("JSON does not support NaN or Infinity");
            }
            builder.append(number);
        } else if (value instanceof Boolean) {
            builder.append(value);
        } else if (value instanceof Map) {
            writeObject(value, builder);
        } else if (value instanceof Collection) {
            writeArray((Collection<?>) value, builder);
        } else if (value.getClass().isArray()) {
            int length = Array.getLength(value);
            List<Object> list = new ArrayList<>(length);
            for (int index = 0; index < length; index += 1) {
                list.add(Array.get(value, index));
            }
            writeArray(list, builder);
        } else {
            throw new GameAlgoException("Unsupported JSON value type: " + value.getClass().getName());
        }
    }

    @SuppressWarnings("unchecked")
    private static void writeObject(Object value, StringBuilder builder) throws GameAlgoException {
        builder.append('{');
        boolean first = true;
        for (Map.Entry<?, ?> entry : ((Map<?, ?>) value).entrySet()) {
            if (!(entry.getKey() instanceof String)) {
                throw new GameAlgoException("JSON object keys must be strings");
            }
            if (!first) {
                builder.append(',');
            }
            writeString((String) entry.getKey(), builder);
            builder.append(':');
            write(entry.getValue(), builder);
            first = false;
        }
        builder.append('}');
    }

    private static void writeArray(Collection<?> values, StringBuilder builder) throws GameAlgoException {
        builder.append('[');
        boolean first = true;
        for (Object value : values) {
            if (!first) {
                builder.append(',');
            }
            write(value, builder);
            first = false;
        }
        builder.append(']');
    }

    private static void writeString(String value, StringBuilder builder) {
        builder.append('"');
        for (int index = 0; index < value.length(); index += 1) {
            char character = value.charAt(index);
            switch (character) {
                case '"':
                    builder.append("\\\"");
                    break;
                case '\\':
                    builder.append("\\\\");
                    break;
                case '\b':
                    builder.append("\\b");
                    break;
                case '\f':
                    builder.append("\\f");
                    break;
                case '\n':
                    builder.append("\\n");
                    break;
                case '\r':
                    builder.append("\\r");
                    break;
                case '\t':
                    builder.append("\\t");
                    break;
                default:
                    if (character < 0x20) {
                        builder.append(String.format("\\u%04x", (int) character));
                    } else {
                        builder.append(character);
                    }
                    break;
            }
        }
        builder.append('"');
    }

    private static final class Parser {
        private final String input;
        private int index;

        Parser(String input) {
            this.input = input == null ? "" : input;
        }

        boolean isAtEnd() {
            return index >= input.length();
        }

        void skipWhitespace() {
            while (!isAtEnd()) {
                char character = input.charAt(index);
                if (character == ' ' || character == '\n' || character == '\r' || character == '\t') {
                    index += 1;
                } else {
                    return;
                }
            }
        }

        Object parseValue() throws GameAlgoException {
            skipWhitespace();
            if (isAtEnd()) {
                throw new GameAlgoException("Invalid JSON: unexpected end");
            }

            char character = input.charAt(index);
            if (character == '"') {
                return parseString();
            }
            if (character == '{') {
                return parseObject();
            }
            if (character == '[') {
                return parseArray();
            }
            if (character == 't') {
                consumeLiteral("true");
                return Boolean.TRUE;
            }
            if (character == 'f') {
                consumeLiteral("false");
                return Boolean.FALSE;
            }
            if (character == 'n') {
                consumeLiteral("null");
                return null;
            }
            if (character == '-' || (character >= '0' && character <= '9')) {
                return parseNumber();
            }
            throw new GameAlgoException("Invalid JSON at position " + index);
        }

        private Map<String, Object> parseObject() throws GameAlgoException {
            expect('{');
            Map<String, Object> object = new LinkedHashMap<>();
            skipWhitespace();
            if (peek('}')) {
                index += 1;
                return object;
            }
            while (true) {
                skipWhitespace();
                String key = parseString();
                skipWhitespace();
                expect(':');
                Object value = parseValue();
                object.put(key, value);
                skipWhitespace();
                if (peek('}')) {
                    index += 1;
                    return object;
                }
                expect(',');
            }
        }

        private List<Object> parseArray() throws GameAlgoException {
            expect('[');
            List<Object> array = new ArrayList<>();
            skipWhitespace();
            if (peek(']')) {
                index += 1;
                return array;
            }
            while (true) {
                array.add(parseValue());
                skipWhitespace();
                if (peek(']')) {
                    index += 1;
                    return array;
                }
                expect(',');
            }
        }

        private String parseString() throws GameAlgoException {
            expect('"');
            StringBuilder builder = new StringBuilder();
            while (!isAtEnd()) {
                char character = input.charAt(index);
                index += 1;
                if (character == '"') {
                    return builder.toString();
                }
                if (character != '\\') {
                    builder.append(character);
                    continue;
                }
                if (isAtEnd()) {
                    throw new GameAlgoException("Invalid JSON string escape");
                }
                char escape = input.charAt(index);
                index += 1;
                switch (escape) {
                    case '"':
                        builder.append('"');
                        break;
                    case '\\':
                        builder.append('\\');
                        break;
                    case '/':
                        builder.append('/');
                        break;
                    case 'b':
                        builder.append('\b');
                        break;
                    case 'f':
                        builder.append('\f');
                        break;
                    case 'n':
                        builder.append('\n');
                        break;
                    case 'r':
                        builder.append('\r');
                        break;
                    case 't':
                        builder.append('\t');
                        break;
                    case 'u':
                        builder.append(parseUnicodeEscape());
                        break;
                    default:
                        throw new GameAlgoException("Invalid JSON string escape");
                }
            }
            throw new GameAlgoException("Invalid JSON string: missing quote");
        }

        private char parseUnicodeEscape() throws GameAlgoException {
            if (index + 4 > input.length()) {
                throw new GameAlgoException("Invalid JSON unicode escape");
            }
            String value = input.substring(index, index + 4);
            index += 4;
            try {
                return (char) Integer.parseInt(value, 16);
            } catch (NumberFormatException error) {
                throw new GameAlgoException("Invalid JSON unicode escape", error);
            }
        }

        private Number parseNumber() throws GameAlgoException {
            int start = index;
            if (peek('-')) {
                index += 1;
            }
            while (!isAtEnd() && Character.isDigit(input.charAt(index))) {
                index += 1;
            }
            boolean decimal = false;
            if (!isAtEnd() && input.charAt(index) == '.') {
                decimal = true;
                index += 1;
                while (!isAtEnd() && Character.isDigit(input.charAt(index))) {
                    index += 1;
                }
            }
            if (!isAtEnd() && (input.charAt(index) == 'e' || input.charAt(index) == 'E')) {
                decimal = true;
                index += 1;
                if (!isAtEnd() && (input.charAt(index) == '+' || input.charAt(index) == '-')) {
                    index += 1;
                }
                while (!isAtEnd() && Character.isDigit(input.charAt(index))) {
                    index += 1;
                }
            }

            String value = input.substring(start, index);
            try {
                return decimal ? Double.parseDouble(value) : Long.parseLong(value);
            } catch (NumberFormatException error) {
                throw new GameAlgoException("Invalid JSON number", error);
            }
        }

        private void consumeLiteral(String literal) throws GameAlgoException {
            if (!input.startsWith(literal, index)) {
                throw new GameAlgoException("Invalid JSON at position " + index);
            }
            index += literal.length();
        }

        private boolean peek(char expected) {
            return !isAtEnd() && input.charAt(index) == expected;
        }

        private void expect(char expected) throws GameAlgoException {
            if (isAtEnd() || input.charAt(index) != expected) {
                throw new GameAlgoException("Expected '" + expected + "' at position " + index);
            }
            index += 1;
        }
    }
}
