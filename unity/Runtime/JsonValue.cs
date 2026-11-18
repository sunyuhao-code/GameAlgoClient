using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace GamePropel
{
    public enum JsonType { Null, Boolean, Number, String, Object, Array }

    /// <summary>JSON data only. No reflection, arbitrary object serialization or external dependencies.</summary>
    public class JsonValue
    {
        public static readonly JsonValue Null = new JsonValue(JsonType.Null, null);
        public JsonType Type { get; }
        private readonly object scalar;
        internal JsonValue(JsonType type, object value) { Type = type; scalar = value; }
        public virtual JsonValue this[string key] { get => throw new InvalidOperationException("Expected a JSON object."); set => throw new InvalidOperationException("Expected a JSON object."); }
        public virtual JsonValue this[int index] { get => throw new InvalidOperationException("Expected a JSON array."); set => throw new InvalidOperationException("Expected a JSON array."); }
        public JsonValue DeepClone() => Clone(0);
        internal virtual JsonValue Clone(int depth) => this; // Scalars are immutable.
        public static JsonValue Parse(string json) => new Reader(json).Read();
        public static JsonValue From(object value)
        {
            if (value == null) return Null;
            if (value is JsonValue node) return node.DeepClone();
            if (value is string text) return text;
            if (value is bool flag) return flag;
            if (value is int i) return (long)i;
            if (value is long l) return l;
            if (value is double d) return d;
            if (value is float f) return f;
            if (value is uint u) return (ulong)u;
            if (value is ulong ul) return ul;
            if (value is short s) return (long)s;
            if (value is ushort us) return (long)us;
            if (value is byte b) return (long)b;
            if (value is sbyte sb) return (long)sb;
            if (value is decimal dec) return dec;
            throw new ArgumentException("Use JSON primitives, JsonObject, JsonArray or JsonValue.Parse for structured data.", nameof(value));
        }
        public T Value<T>(string key) => (this[key] ?? Null).Value<T>();
        public T Value<T>()
        {
            if (this is T node) return node;
            if (Type == JsonType.Null)
            {
                if (default(T) == null) return default;
                throw new InvalidCastException("JSON null cannot be converted to a value type.");
            }
            var target = Nullable.GetUnderlyingType(typeof(T)) ?? typeof(T);
            object result;
            if (target == typeof(string) && Type == JsonType.String) result = scalar;
            else if (target == typeof(bool) && Type == JsonType.Boolean) result = scalar;
            else if (Type == JsonType.Number)
            {
                var number = (string)scalar;
                if (target == typeof(int)) result = int.Parse(number, NumberStyles.Integer, CultureInfo.InvariantCulture);
                else if (target == typeof(long)) result = long.Parse(number, NumberStyles.Integer, CultureInfo.InvariantCulture);
                else if (target == typeof(uint)) result = uint.Parse(number, NumberStyles.Integer, CultureInfo.InvariantCulture);
                else if (target == typeof(ulong)) result = ulong.Parse(number, NumberStyles.Integer, CultureInfo.InvariantCulture);
                else if (target == typeof(short)) result = short.Parse(number, NumberStyles.Integer, CultureInfo.InvariantCulture);
                else if (target == typeof(ushort)) result = ushort.Parse(number, NumberStyles.Integer, CultureInfo.InvariantCulture);
                else if (target == typeof(byte)) result = byte.Parse(number, NumberStyles.Integer, CultureInfo.InvariantCulture);
                else if (target == typeof(sbyte)) result = sbyte.Parse(number, NumberStyles.Integer, CultureInfo.InvariantCulture);
                else if (target == typeof(decimal)) result = decimal.Parse(number, NumberStyles.Float, CultureInfo.InvariantCulture);
                else if (target == typeof(float))
                {
                    var f = float.Parse(number, NumberStyles.Float, CultureInfo.InvariantCulture);
                    if (float.IsInfinity(f)) throw new OverflowException("JSON number is outside the float range.");
                    result = f;
                }
                else if (target == typeof(double))
                {
                    var d = double.Parse(number, NumberStyles.Float, CultureInfo.InvariantCulture);
                    if (double.IsInfinity(d)) throw new OverflowException("JSON number is outside the double range.");
                    result = d;
                }
                else throw new InvalidCastException("Unsupported JSON conversion. Read a JSON node or primitive.");
            }
            else throw new InvalidCastException("JSON type does not match the requested type.");
            return (T)result;
        }
        public static implicit operator JsonValue(string value) => value == null ? Null : new JsonValue(JsonType.String, value);
        public static implicit operator JsonValue(bool value) => new JsonValue(JsonType.Boolean, value);
        public static implicit operator JsonValue(int value) => (long)value;
        public static implicit operator JsonValue(uint value) => (ulong)value;
        public static implicit operator JsonValue(long value) => Number(value.ToString(CultureInfo.InvariantCulture));
        public static implicit operator JsonValue(ulong value) => Number(value.ToString(CultureInfo.InvariantCulture));
        public static implicit operator JsonValue(float value)
        {
            if (float.IsNaN(value) || float.IsInfinity(value)) throw new ArgumentOutOfRangeException(nameof(value));
            return Number(value.ToString("R", CultureInfo.InvariantCulture));
        }
        public static implicit operator JsonValue(double value)
        {
            if (double.IsNaN(value) || double.IsInfinity(value)) throw new ArgumentOutOfRangeException(nameof(value));
            return Number(value.ToString("R", CultureInfo.InvariantCulture));
        }
        public static implicit operator JsonValue(decimal value) => Number(value.ToString(CultureInfo.InvariantCulture));
        private static JsonValue Number(string value) => new JsonValue(JsonType.Number, value);
        public sealed override string ToString()
        {
            var output = new StringBuilder(); Write(output, 0); return output.ToString();
        }
        internal virtual void Write(StringBuilder output, int depth)
        {
            if (Type == JsonType.String) WriteString(output, (string)scalar);
            else if (Type == JsonType.Boolean) output.Append((bool)scalar ? "true" : "false");
            else if (Type == JsonType.Number) output.Append((string)scalar);
            else output.Append("null");
        }
        internal static void CheckDepth(int depth)
        {
            if (depth >= 64) throw new FormatException("JSON nesting exceeds 64 containers or contains a cycle.");
        }
        internal static void WriteString(StringBuilder output, string value)
        {
            output.Append('"');
            for (var i = 0; i < value.Length; i++)
            {
                var c = value[i];
                switch (c)
                {
                    case '"': output.Append("\\\""); break;
                    case '\\': output.Append("\\\\"); break;
                    case '\b': output.Append("\\b"); break;
                    case '\f': output.Append("\\f"); break;
                    case '\n': output.Append("\\n"); break;
                    case '\r': output.Append("\\r"); break;
                    case '\t': output.Append("\\t"); break;
                    default:
                        if (c < 32 || char.IsSurrogate(c))
                        { output.Append("\\u"); output.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); }
                        else output.Append(c);
                        break;
                }
            }
            output.Append('"');
        }
        private sealed class Reader
        {
            private readonly string text;
            private int position;
            internal Reader(string text) { this.text = text ?? throw new ArgumentNullException(nameof(text)); }
            internal JsonValue Read()
            {
                var value = ReadValue(0); White();
                if (position != text.Length) throw Error();
                return value;
            }
            private FormatException Error() => new FormatException("Invalid JSON at character " + position.ToString(CultureInfo.InvariantCulture) + ".");
            private void White() { while (position < text.Length && (text[position] == ' ' || text[position] == '\t' || text[position] == '\r' || text[position] == '\n')) position++; }
            private bool Take(char c) { if (position < text.Length && text[position] == c) { position++; return true; } return false; }
            private void Need(char c) { if (!Take(c)) throw Error(); }
            private JsonValue Literal(string expected, JsonValue result)
            {
                for (var i = 0; i < expected.Length; i++) Need(expected[i]);
                return result;
            }
            private JsonValue ReadValue(int depth)
            {
                White(); if (position == text.Length) throw Error();
                var c = text[position];
                if (c == '"') return String();
                if (c == 'n') return Literal("null", Null);
                if (c == 't') return Literal("true", true);
                if (c == 'f') return Literal("false", false);
                if (c == '{')
                {
                    CheckDepth(depth); position++; White(); var value = new JsonObject();
                    if (Take('}')) return value;
                    do { White(); var key = String(); White(); Need(':'); value[key] = ReadValue(depth + 1); White(); if (Take('}')) return value; Need(','); } while (true);
                }
                if (c == '[')
                {
                    CheckDepth(depth); position++; White(); var value = new JsonArray();
                    if (Take(']')) return value;
                    do { value.Add(ReadValue(depth + 1)); White(); if (Take(']')) return value; Need(','); } while (true);
                }
                var start = position;
                Take('-');
                if (!Take('0')) { if (position >= text.Length || text[position] < '1' || text[position] > '9') throw Error(); Digits(); }
                if (Take('.')) { var digit = position; Digits(); if (digit == position) throw Error(); }
                if (Take('e') || Take('E')) { if (!Take('+')) Take('-'); var digit = position; Digits(); if (digit == position) throw Error(); }
                return Number(text.Substring(start, position - start));
            }
            private void Digits() { while (position < text.Length && text[position] >= '0' && text[position] <= '9') position++; }
            private string String()
            {
                Need('"'); var output = new StringBuilder();
                while (position < text.Length)
                {
                    var c = text[position++];
                    if (c == '"') return output.ToString();
                    if (c < 32) throw Error();
                    if (c != '\\') { output.Append(c); continue; }
                    if (position == text.Length) throw Error();
                    c = text[position++];
                    switch (c)
                    {
                        case '"': case '\\': case '/': output.Append(c); break;
                        case 'b': output.Append('\b'); break;
                        case 'f': output.Append('\f'); break;
                        case 'n': output.Append('\n'); break;
                        case 'r': output.Append('\r'); break;
                        case 't': output.Append('\t'); break;
                        case 'u':
                            var code = 0;
                            for (var i = 0; i < 4; i++)
                            {
                                if (position == text.Length) throw Error();
                                var h = text[position++];
                                var digit = h >= '0' && h <= '9' ? h - '0' : h >= 'a' && h <= 'f' ? h - 'a' + 10 : h >= 'A' && h <= 'F' ? h - 'A' + 10 : -1;
                                if (digit < 0) throw Error(); code = code * 16 + digit;
                            }
                            output.Append((char)code); break;
                        default: throw Error();
                    }
                }
                throw Error();
            }
        }
    }

    public sealed class JsonObject : JsonValue, IEnumerable<KeyValuePair<string, JsonValue>>
    {
        private readonly Dictionary<string, JsonValue> values = new Dictionary<string, JsonValue>(StringComparer.Ordinal);
        public JsonObject() : base(JsonType.Object, null) { }
        public int Count => values.Count;
        public override JsonValue this[string key] { get => values.TryGetValue(key, out var value) ? value : null; set => values[key] = value ?? Null; }
        public new static JsonObject Parse(string json) => JsonValue.Parse(json) as JsonObject ?? throw new FormatException("Expected a JSON object.");
        internal override JsonValue Clone(int depth)
        {
            CheckDepth(depth); var copy = new JsonObject();
            foreach (var pair in values) copy[pair.Key] = pair.Value.Clone(depth + 1);
            return copy;
        }
        public IEnumerator<KeyValuePair<string, JsonValue>> GetEnumerator() => values.GetEnumerator();
        IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
        internal override void Write(StringBuilder output, int depth)
        {
            CheckDepth(depth); output.Append('{'); var first = true;
            foreach (var pair in values)
            { if (!first) output.Append(','); first = false; WriteString(output, pair.Key); output.Append(':'); pair.Value.Write(output, depth + 1); }
            output.Append('}');
        }
    }

    public sealed class JsonArray : JsonValue, IEnumerable<JsonValue>
    {
        private readonly List<JsonValue> values = new List<JsonValue>();
        public JsonArray() : base(JsonType.Array, null) { }
        public int Count => values.Count;
        public void Add(JsonValue value) => values.Add(value ?? Null);
        public override JsonValue this[int index] { get => values[index]; set => values[index] = value ?? Null; }
        internal override JsonValue Clone(int depth)
        {
            CheckDepth(depth); var copy = new JsonArray();
            foreach (var value in values) copy.Add(value.Clone(depth + 1));
            return copy;
        }
        public IEnumerator<JsonValue> GetEnumerator() => values.GetEnumerator();
        IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
        internal override void Write(StringBuilder output, int depth)
        {
            CheckDepth(depth); output.Append('[');
            for (var i = 0; i < values.Count; i++) { if (i != 0) output.Append(','); values[i].Write(output, depth + 1); }
            output.Append(']');
        }
    }
}
