using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using GamePropel;

internal static class JsonTests
{
    private static int checks;
    private static void Check(bool condition, string message)
    { checks++; if (!condition) throw new Exception("JSON: " + message); }
    private static void Reject(Action action, string message)
    {
        try { action(); }
        catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidCastException || error is OverflowException) { checks++; return; }
        throw new Exception("JSON accepted " + message);
    }
    internal static void Run()
    {
        var json = JsonObject.Parse("{\"signed\":-9223372036854775808,\"unsigned\":18446744073709551615,\"precise\":9007199254740993,\"s\":\"中文\\uD83D\\uDE00\\n\\t\\u0000\\\"\\\\\\/\",\"a\":[true,false,null,1.25e-2]}");
        Check(json.Value<long>("signed") == long.MinValue, "signed 64-bit precision");
        Check(json.Value<ulong>("unsigned") == ulong.MaxValue, "unsigned 64-bit precision");
        Check(json.Value<long>("precise") == 9007199254740993L, "integers above 2^53");
        Check(json.Value<string>("s") == "中文😀\n\t\0\"\\/", "Unicode and JSON escapes");
        Check(json["a"][0].Value<bool>() && !json["a"][1].Value<bool>(), "booleans");
        Check(json["a"][2].Type == JsonType.Null && json["a"][2].Value<string>() == null, "explicit null");
        Check(json["a"][3].Value<decimal>() == 0.0125m, "exponents");
        Check(json["missing"] == null && json.Value<bool?>("missing") == null, "missing and nullable fields");
        Check(JsonValue.Parse("true").Value<bool?>() == true, "nullable boolean conversion");
        Reject(() => json["a"][3].Value<int>(), "fractional integer conversion");
        Reject(() => json["unsigned"].Value<long>(), "overflow conversion");
        Reject(() => JsonValue.Parse("1e400").Value<double>(), "infinite conversion");
        Reject(() => JsonValue.From(double.NaN), "NaN");
        Reject(() => JsonValue.From(float.PositiveInfinity), "infinity");
        Reject(() => JsonValue.From(new object()), "reflection-based arbitrary objects");
        Reject(() => JsonObject.Parse("[]"), "array where an object is required");
        foreach (var invalid in new[] { "", " ", "01", "-01", "-", "+1", ".1", "1.", "1e", "1e+", "1e--1", "NaN", "Infinity", "undefined", "null true", "truex", "[1,]", "[1 2]", "[", "{", "{\"a\":}", "{a:1}", "{\"a\":1,}", "\"\\x20\"", "\"\\u0q00\"", "\"\\u123\"", "\"unterminated", "\"a\nb\"", "\u00a0null" })
            Reject(() => JsonValue.Parse(invalid), invalid);
        var sixtyFour = new string('[', 64) + "0" + new string(']', 64);
        Check(JsonValue.Parse(sixtyFour).ToString() == sixtyFour, "64 levels allowed");
        Reject(() => JsonValue.Parse("[" + sixtyFour + "]"), "excess nesting");
        var cycle = new JsonObject(); cycle["self"] = cycle;
        Reject(() => cycle.ToString(), "cyclic serialization");
        Reject(() => cycle.DeepClone(), "cyclic cloning");
        var copy = (JsonObject)json.DeepClone(); copy["a"][0] = false;
        Check(json["a"][0].Value<bool>(), "nested clone isolation");
        Check(JsonObject.Parse("{\"a\":1,\"a\":2}").Value<int>("a") == 2, "last duplicate key wins");

        var culture = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new CultureInfo("fr-FR");
            Check(JsonValue.From(1.25).ToString() == "1.25", "locale independent writer");
            Check(JsonValue.Parse("1.25").Value<double>() == 1.25, "locale independent reader");
            var random = new Random(28024);
            for (var i = 0; i < 1500; i++)
            {
                // Independent .NET JSON implementation is used only in the host-side test executable.
                var reference = JsonSerializer.Serialize(Generate(random, 0));
                using (var expected = JsonDocument.Parse(reference))
                using (var actual = JsonDocument.Parse(JsonValue.Parse(reference).DeepClone().ToString()))
                    Compare(expected.RootElement, actual.RootElement);
            }
        }
        finally { CultureInfo.CurrentCulture = culture; }
        Console.WriteLine("Independent JSON checks passed: " + checks);
    }
    private static object Generate(Random random, int depth)
    {
        switch (random.Next(depth < 5 ? 8 : 6))
        {
            case 0: return null;
            case 1: return random.Next(2) == 0;
            case 2: return ((long)random.Next() << 32) | (uint)random.Next();
            case 3: return (random.NextDouble() - 0.5) * 1e20;
            case 4: return "\0\b\f\n\r\t\\\"中文😀é" + random.Next().ToString(CultureInfo.InvariantCulture);
            case 5: return -(decimal)random.NextDouble() / 1000;
            case 6:
                var list = new List<object>();
                for (var i = random.Next(5); i > 0; i--) list.Add(Generate(random, depth + 1));
                return list;
            default:
                var dict = new Dictionary<string, object>();
                for (var i = random.Next(5); i > 0; i--) dict["键\\\"" + i] = Generate(random, depth + 1);
                return dict;
        }
    }
    private static void Compare(JsonElement expected, JsonElement actual)
    {
        Check(expected.ValueKind == actual.ValueKind, "reference type");
        switch (expected.ValueKind)
        {
            case JsonValueKind.Object:
                var count = 0;
                foreach (var pair in expected.EnumerateObject()) { Compare(pair.Value, actual.GetProperty(pair.Name)); count++; }
                var actualCount = 0; foreach (var unused in actual.EnumerateObject()) actualCount++;
                Check(count == actualCount, "reference object members"); break;
            case JsonValueKind.Array:
                Check(expected.GetArrayLength() == actual.GetArrayLength(), "reference array length");
                for (var i = 0; i < expected.GetArrayLength(); i++) Compare(expected[i], actual[i]); break;
            case JsonValueKind.String: Check(expected.GetString() == actual.GetString(), "reference string"); break;
            default: Check(expected.GetRawText() == actual.GetRawText(), "reference scalar precision"); break;
        }
    }
}
