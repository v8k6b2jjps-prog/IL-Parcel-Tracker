using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Xml.Linq;

namespace ParcelTracker
{
    public partial class MainWindow : Window
    {
        const string UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36";
        const string IPOST_KEY = "5ccb5b137e7444d885be752eda7f767a"; // public frontend key from doar.israelpost.co.il

        static readonly HttpClient Http = new HttpClient(new HttpClientHandler
        {
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli
        });

        public MainWindow()
        {
            InitializeComponent();
            try { Encoding.RegisterProvider(CodePagesEncodingProvider.Instance); } catch { }
        }

        // ---------- helpers ----------
        static string NormalizeNum(string s) => Regex.Replace(s ?? "", "[^A-Za-z0-9]", "").ToUpperInvariant();

        static string DetectCarrier(string n)
        {
            if (n.StartsWith("ED")) return "HFD";
            if (n.StartsWith("AE")) return "Chita";
            if (n.StartsWith("RS")) return "Post";
            if (Regex.IsMatch(n, "^[A-Z]{2}\\d{6,}[A-Z]?$")) return "Post"; // S10-style international mail
            return null;
        }

        static string DecodeHtml(byte[] bytes)
        {
            var u = Encoding.UTF8.GetString(bytes);
            if (u.IndexOf('�') >= 0) return Encoding.GetEncoding(1255).GetString(bytes);
            return u;
        }

        async Task<byte[]> GetBytes(string url, Action<HttpRequestMessage> configure)
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("User-Agent", UA);
            configure?.Invoke(req);
            using var resp = await Http.SendAsync(req);
            resp.EnsureSuccessStatusCode();
            return await resp.Content.ReadAsByteArrayAsync();
        }

        static XDocument LoadXml(byte[] bytes)
        {
            using var ms = new MemoryStream(bytes);
            return XDocument.Load(ms); // honors the XML declaration's encoding
        }

        static string XVal(XDocument d, string name) =>
            (d.Descendants().FirstOrDefault(e => e.Name.LocalName == name)?.Value ?? "").Trim();

        static (string Internal, List<string> Lines) ParseRunCom(string html)
        {
            var lines = new List<string>();
            var im = Regex.Match(html, @":\s*(\d{4,})\s*</span>");
            string internalNum = im.Success ? im.Groups[1].Value : "";
            foreach (Match m in Regex.Matches(html,
                @"<tr>\s*<td>([^<]*?)</td>\s*<td>([^<]*?)</td>\s*<td>(.*?)</td>\s*</tr>", RegexOptions.Singleline))
            {
                string desc = Regex.Replace(m.Groups[3].Value, "<[^>]+>", " ");
                desc = Regex.Replace(WebUtility.HtmlDecode(desc), "\\s{2,}", " ").Trim();
                lines.Add($"{m.Groups[1].Value.Trim()}  {m.Groups[2].Value.Trim()}   {desc}");
            }
            return (internalNum, lines);
        }

        class Result
        {
            public bool Found;
            public string Status = "";
            public List<string> Lines = new List<string>();
        }

        static Result NotFound(string msg)
        {
            var r = new Result { Found = false };
            r.Lines.Add("Not found: " + msg);
            return r;
        }

        // ---------- carriers ----------
        async Task<Result> TrackHfd(string num, string phone)
        {
            string referer = "https://run.hfd.co.il/run_public/pub_random_form.htm";
            string api = "https://api.hfd.co.il/rest/v3/api/ship-locate-num-and-phone?num="
                       + Uri.EscapeDataString(num) + "&phone=" + Uri.EscapeDataString(phone);
            var doc = LoadXml(await GetBytes(api, r => r.Headers.TryAddWithoutValidation("Referer", referer)));

            string msg = XVal(doc, "status_message");
            string tok = XVal(doc, "ship_rand_num");
            if (!string.IsNullOrEmpty(msg)) return NotFound(msg);
            if (string.IsNullOrEmpty(tok)) return NotFound("no token returned");

            string detail = "https://run.hfd.co.il/runcom.server/request.aspx?APPNAME=run&PRGNAME=ship_locate_random&ARGUMENTS=-A" + tok;
            var (intn, lines) = ParseRunCom(DecodeHtml(await GetBytes(detail, r => r.Headers.TryAddWithoutValidation("Referer", referer))));
            if (lines.Count == 0) return NotFound("no events (possibly not found)");

            var res = new Result { Found = true, Status = $"HFD - found (internal: {intn})" };
            res.Lines.Add($"HFD - {num}    internal: {intn}");
            res.Lines.Add(new string('-', 80));
            res.Lines.AddRange(lines);
            return res;
        }

        async Task<Result> TrackChita(string num, string phone)
        {
            string referer = "https://chita-il.com/run_public1/";
            string step1 = "https://chita-il.com/RunCom.Server/Request.aspx?APPNAME=RUN&PRGNAME=ship_locate_num_and_phone&ARGUMENTS=-N"
                         + Uri.EscapeDataString(num) + ",-A" + Uri.EscapeDataString(phone);
            var doc = LoadXml(await GetBytes(step1, r =>
            {
                r.Headers.TryAddWithoutValidation("X-Requested-With", "XMLHttpRequest");
                r.Headers.TryAddWithoutValidation("Referer", referer);
            }));

            string msg = XVal(doc, "status_message");
            string tok = XVal(doc, "ship_rand_num");
            if (!string.IsNullOrEmpty(msg)) return NotFound(msg);
            if (string.IsNullOrEmpty(tok)) return NotFound("no token returned");

            string detail = "https://chita-il.com/RunCom.Server/Request.aspx?APPNAME=run&PRGNAME=ship_locate_random&ARGUMENTS=-A" + tok;
            var (intn, lines) = ParseRunCom(DecodeHtml(await GetBytes(detail, r => r.Headers.TryAddWithoutValidation("Referer", referer))));
            if (lines.Count == 0) return NotFound("no events (possibly not found)");

            var res = new Result { Found = true, Status = $"Chita - found (internal: {intn})" };
            res.Lines.Add($"Chita - {num}    internal: {intn}");
            res.Lines.Add(new string('-', 80));
            res.Lines.AddRange(lines);
            return res;
        }

        async Task<Result> TrackPost(string num)
        {
            string url = "https://apimftprd.israelpost.co.il/MyPost-itemtrace/items/" + Uri.EscapeDataString(num) + "/heb";
            var bytes = await GetBytes(url, r =>
            {
                r.Headers.TryAddWithoutValidation("Accept", "application/json, text/plain, */*");
                r.Headers.TryAddWithoutValidation("Origin", "https://doar.israelpost.co.il");
                r.Headers.TryAddWithoutValidation("Ocp-Apim-Subscription-Key", IPOST_KEY);
            });
            string json = Encoding.UTF8.GetString(bytes);

            using var jdoc = JsonDocument.Parse(json);
            JsonElement best = default; int bestCount = 0;
            FindEventArray(jdoc.RootElement, ref best, ref bestCount);

            var res = new Result();
            if (bestCount == 0)
            {
                res.Found = false;
                res.Lines.Add("No updates. Raw JSON:");
                res.Lines.Add(new string('-', 80));
                res.Lines.Add(json);
                return res;
            }

            var events = best.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.Object).ToList();
            string latest = GetProp(events[0], "CategoryName");
            res.Found = true;
            res.Status = string.IsNullOrEmpty(latest) ? "Israel Post" : "Israel Post - " + latest;
            res.Lines.Add("Israel Post - " + num);
            res.Lines.Add("Date  |  Status  |  Detail");
            res.Lines.Add(new string('-', 80));
            foreach (var e in events)
            {
                string d = GetProp(e, "StatusDate"), c = GetProp(e, "CategoryName"), s = GetProp(e, "Status");
                if (!string.IsNullOrEmpty(d) || !string.IsNullOrEmpty(s))
                    res.Lines.Add($"{d}  |  {c}  |  {s}");
                else
                    res.Lines.Add(Flatten(e));
            }
            return res;
        }

        static void FindEventArray(JsonElement el, ref JsonElement best, ref int bestCount)
        {
            if (el.ValueKind == JsonValueKind.Array)
            {
                int objs = el.EnumerateArray().Count(x => x.ValueKind == JsonValueKind.Object);
                if (objs > 0 && objs >= bestCount) { bestCount = objs; best = el; }
                foreach (var it in el.EnumerateArray()) FindEventArray(it, ref best, ref bestCount);
            }
            else if (el.ValueKind == JsonValueKind.Object)
            {
                foreach (var p in el.EnumerateObject()) FindEventArray(p.Value, ref best, ref bestCount);
            }
        }

        static string GetProp(JsonElement obj, string name)
        {
            foreach (var p in obj.EnumerateObject())
                if (string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase))
                    return p.Value.ValueKind == JsonValueKind.String ? (p.Value.GetString() ?? "").Trim() : p.Value.ToString();
            return "";
        }

        static string Flatten(JsonElement obj)
        {
            var parts = new List<string>();
            foreach (var p in obj.EnumerateObject())
            {
                if (p.Value.ValueKind == JsonValueKind.Array || p.Value.ValueKind == JsonValueKind.Object) continue;
                string v = (p.Value.ValueKind == JsonValueKind.String ? p.Value.GetString() : p.Value.ToString()) ?? "";
                v = v.Trim();
                if (v.Length > 0 && v != "null") parts.Add($"{p.Name}={v}");
            }
            return string.Join("  |  ", parts);
        }

        // ---------- UI ----------
        async void BtnTrack_Click(object sender, RoutedEventArgs e)
        {
            string num = NormalizeNum(TxtNum.Text);
            string phone = Regex.Replace(TxtPhone.Text ?? "", "\\D", "");
            TxtOut.Clear();
            TxtStatus.Text = "";

            if (string.IsNullOrEmpty(num)) { TxtOut.Text = "Enter a tracking number."; return; }

            string carrier = DetectCarrier(num);
            if (carrier == null)
            {
                string seen = num.Length >= 2 ? num.Substring(0, 2) : num;
                TxtOut.Text = $"Carrier not recognized from prefix '{seen}' (expected ED / AE / RS).";
                return;
            }
            if ((carrier == "HFD" || carrier == "Chita") && string.IsNullOrEmpty(phone))
            {
                TxtOut.Text = $"Detected {carrier} - a phone number is required.";
                return;
            }

            BtnTrack.IsEnabled = false;
            TxtStatus.Text = $"Searching... ({carrier})";
            try
            {
                Result r =
                    carrier == "HFD" ? await TrackHfd(num, phone) :
                    carrier == "Chita" ? await TrackChita(num, phone) :
                    await TrackPost(num);

                TxtStatus.Text = r.Status;
                TxtOut.Text = string.Join("\r\n", r.Lines);
            }
            catch (Exception ex)
            {
                TxtStatus.Text = "";
                TxtOut.Text = "Error: " + ex.Message;
            }
            finally
            {
                BtnTrack.IsEnabled = true;
            }
        }
    }
}
