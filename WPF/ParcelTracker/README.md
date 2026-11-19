# Parcel Tracker (C# / WPF)

Tracks **HFD**, **Israel Post (דואר ישראל)** and **Chita (ציטה)** shipments.
The carrier is auto-detected from the tracking-number prefix:

| Prefix | Carrier       | Needs phone |
|--------|---------------|-------------|
| `ED…`  | HFD           | yes         |
| `AE…`  | Chita         | yes         |
| `RS…`  | Israel Post   | no          |

## Build & run

Requires the **.NET 8 SDK** (Windows). From this folder:

```powershell
dotnet run
```

or build a release binary:

```powershell
dotnet build -c Release
# -> bin\Release\net8.0-windows\ParcelTracker.exe
```

Or just open `ParcelTracker.csproj` in Visual Studio 2022 and press F5.

### Self-contained single .exe (no .NET install needed on the target)

```powershell
dotnet publish -c Release -r win-x64 --self-contained true `
  /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true
```

### Don't have .NET 8?
Change `<TargetFramework>` in `ParcelTracker.csproj` to `net6.0-windows`
(or `net48` if you build with the .NET Framework targeting pack).

## How it works
- **HFD / Chita** use the same RunCom system: a step-1 XML call returns a
  `ship_rand_num` token, then a step-2 HTML page carries the timeline
  (auto-decoded as UTF-8, falling back to Windows-1255).
- **Israel Post** calls the MyPost JSON API and shows `Date | Status | Detail`.

The Israel Post `Ocp-Apim-Subscription-Key` is the site's public frontend key.
