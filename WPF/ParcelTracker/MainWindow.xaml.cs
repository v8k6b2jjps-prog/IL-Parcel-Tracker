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
            if (n.StartsWith("SN")) return "GCX";
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

        // ---------- GCX (info.gcx.co.il — ASP.NET postback: GET tokens, then POST) ----------
        static string GcxSpan(string html, string id)
        {
            var m = Regex.Match(html, "<span[^>]*id=\"" + Regex.Escape(id) + "\"[^>]*>(.*?)</span>", RegexOptions.Singleline);
            if (!m.Success) return "";
            string t = Regex.Replace(m.Groups[1].Value, "<[^>]+>", " ");
            return Regex.Replace(WebUtility.HtmlDecode(t), "\\s{2,}", " ").Trim();
        }

        async Task<Result> TrackGcx(string num)
        {
            const string gurl = "https://info.gcx.co.il/gcx_event/Default.aspx";

            // GCX ties VIEWSTATE to an ASP.NET session cookie, so use a cookie-aware client.
            using var handler = new HttpClientHandler
            {
                AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
                CookieContainer = new CookieContainer(),
                UseCookies = true
            };
            using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };

            // Step 1 — GET to harvest tokens + the session cookie.
            string html1;
            using (var getReq = new HttpRequestMessage(HttpMethod.Get, gurl))
            {
                getReq.Headers.TryAddWithoutValidation("User-Agent", UA);
                getReq.Headers.TryAddWithoutValidation("Accept", "text/html,*/*");
                using var getResp = await http.SendAsync(getReq);
                getResp.EnsureSuccessStatusCode();
                html1 = Encoding.UTF8.GetString(await getResp.Content.ReadAsByteArrayAsync());
            }

            string Pick(string name)
            {
                var m = Regex.Match(html1, "name=\"" + name + "\"[^>]*?value=\"([^\"]*)\"");
                return m.Success ? WebUtility.HtmlDecode(m.Groups[1].Value) : "";
            }
            string vs = Pick("__VIEWSTATE");
            if (string.IsNullOrEmpty(vs)) return NotFound("GCX: no __VIEWSTATE (page changed or blocked)");

            // Step 2 — POST the number with the harvested tokens (cookie flows automatically).
            var form = new Dictionary<string, string>
            {
                ["__EVENTTARGET"] = "",
                ["__EVENTARGUMENT"] = "",
                ["__VIEWSTATE"] = vs,
                ["__VIEWSTATEGENERATOR"] = Pick("__VIEWSTATEGENERATOR"),
                ["__EVENTVALIDATION"] = Pick("__EVENTVALIDATION"),
                ["tbHAWB_NUM"] = num,
                ["BtnTrack"] = "TRACK / עקוב"
            };
            byte[] bytes;
            using (var postReq = new HttpRequestMessage(HttpMethod.Post, gurl) { Content = new FormUrlEncodedContent(form) })
            {
                postReq.Headers.TryAddWithoutValidation("User-Agent", UA);
                postReq.Headers.TryAddWithoutValidation("Accept", "text/html,*/*");
                postReq.Headers.TryAddWithoutValidation("Referer", gurl);
                postReq.Headers.TryAddWithoutValidation("Origin", "https://info.gcx.co.il");
                using var postResp = await http.SendAsync(postReq);
                postResp.EnsureSuccessStatusCode();
                bytes = await postResp.Content.ReadAsByteArrayAsync();
            }
            string html = DecodeHtml(bytes);

            var idx = Regex.Matches(html, "id=\"lbEventDescrEng(\\d+)\"")
                           .Select(m => int.Parse(m.Groups[1].Value)).Distinct().OrderBy(x => x).ToList();
            var lines = new List<string>();
            foreach (int i in idx)
            {
                string eng = GcxSpan(html, "lbEventDescrEng" + i);
                string heb = GcxSpan(html, "lbEventDescrHeb" + i);
                string date = GcxSpan(html, "lbEventDate" + i);
                string time = GcxSpan(html, "lbEventTime" + i);
                string st = !string.IsNullOrEmpty(heb)
                    ? (!string.IsNullOrEmpty(eng) ? eng + " / " + heb : heb)
                    : eng;
                lines.Add($"{date}  {time}   {st}");
            }
            string cur = GcxSpan(html, "LbCurrentStatusEng");
            if (string.IsNullOrEmpty(cur) && lines.Count == 0) return NotFound("not found / no data");

            string company = GcxSpan(html, "lbDeliveryCompnyName");
            string via = string.IsNullOrEmpty(company) ? "" : "via " + company;

            var res = new Result { Found = true, Status = string.IsNullOrEmpty(via) ? "GCX - found" : "GCX - found  " + via };
            res.Lines.Add($"GCX - {num}    {via}".TrimEnd());
            res.Lines.Add(new string('-', 80));
            res.Lines.AddRange(lines);
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
                TxtOut.Text = $"Carrier not recognized from prefix '{seen}' (expected ED / AE / SN / RS).";
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
                    carrier == "GCX" ? await TrackGcx(num) :
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
