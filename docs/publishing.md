# Publishing from Clipper

Clipper publishes with **your own developer apps** ("bring your own keys"). Client IDs, secrets, tokens and storage keys live in your Mac's **Keychain** (service `dev.yashjain.clipper.publish`). There's no Clipper server, and nothing is posted unless you run `clipper publish now|run-due` or press Publish in the app.

| | YouTube | TikTok | Instagram |
|---|---|---|---|
| What you need | Google Cloud project + Desktop OAuth client | TikTok for Developers Desktop app | Meta app (Instagram Login) + Professional account + R2/S3 bucket |
| Sign-in | Browser → loopback `127.0.0.1` callback (PKCE) | Browser → loopback callback (PKCE, hex S256) | Browser → paste the redirected https URL |
| What happens | Resumable upload (+ SRT captions) | Draft in your TikTok inbox: finish it in the app | Reel published (public), temporary bucket file deleted |
| Limits | 100 uploads/day | 5 pending drafts/24 h while unaudited | 100 posts/24 h; 3 s–15 min; ≤ 300 MB |

```bash
clipper publish connect youtube --help-setup   # how to create the app (same for tiktok, instagram)
clipper publish connect youtube                # enter keys once, sign in in the browser
clipper publish status
clipper publish now "3 tips" --to youtube,tiktok --visibility unlisted
clipper publish schedule "3 tips" --to youtube --at "2026-10-20 18:30"
clipper publish run-due                        # or: clipper publish install-agent (every 15 min)
clipper publish calendar                       # .ics feed for Calendar/Notion
```

In the app: **Settings ▸ Accounts** (keys, Connect, setup guides), **Publish…** in the editor, and **Publishing** in the sidebar.

## Description, chapters and hashtags

A draft made with the local LLM (`clipper draft --llm …`, or the app with the local LLM on) keeps the brief's
description and hashtags on the timeline. The Publish sheet and `clipper publish now|schedule` (without
`--description`/`--tags`) start from:
- **Title**: the timeline's name.
- **Description**: the brief's description, then a YouTube chapter list made from the timeline's `Chapter: <title>`
  markers (`0:00 Intro`, `1:05 Setup`, …), then the hashtags on one line. The list is left out unless there are at
  least 3 chapter markers and every chapter lasts at least 10 s. A first chapter in the first 10 s starts at 0:00;
  a later one gets `0:00 Intro` before it.
- **Tags**: the hashtags.

Music credits are still appended after all of this. When YouTube's 5,000-byte limit is exceeded, the prose is
shortened first, then the hashtag line goes, then chapters from the end; the credits are never cut.
`clipper publish now … --dry-run` prints the title, tags and full description without exporting or uploading.

## YouTube

1. Open https://console.cloud.google.com/ and create a project.
2. Go to **APIs & Services → Library** and enable **YouTube Data API v3**.
3. Set up the **OAuth consent screen**:
   - user type **External**;
   - add your Google account as a **test user**;
   - add the scopes `https://www.googleapis.com/auth/youtube.upload` and `https://www.googleapis.com/auth/youtube.force-ssl` (the second is for captions).
4. Go to **Clients → Create client** and choose **Desktop app**. You don't register a redirect URI: Clipper listens on `http://127.0.0.1:<random port>/callback`, which desktop clients allow.
5. Run `clipper publish connect youtube` (or use the app's Accounts tab) and paste the Client ID and secret.

Notes:
- Google's current `videos.insert` docs say videos from unverified API projects are **no longer restricted to private**. If yours stay private, request the API compliance audit.
- While the consent screen is in "Testing", refresh tokens expire after **7 days**, so reconnect weekly or publish the consent screen.
- Captions are uploaded from the exported `.srt` files, one per language: `<name>.<lang>.srt` for each tagged caption track, and the plain `<name>.srt` (labelled with the visible captions' language) only when no tagged file already carries it.

## TikTok

1. Open https://developers.tiktok.com/ and go to **Manage apps → Connect an app**, platform **Desktop**.
2. Add **Login Kit** and **Content Posting API**, with the scopes `user.info.basic` and `video.upload`.
3. Under Login Kit, set the Desktop redirect URI to exactly `http://127.0.0.1:*/callback/`.
4. Until the app is approved, use the **Sandbox** and add your account as a target user.
5. Run `clipper publish connect tiktok` and paste the Client key and secret.

Clipper uploads a **draft** to your inbox. You add the caption and sound and post it in the TikTok app; Clipper prints a suggested caption with the music credits.

## Instagram

Reels go through the **Instagram API with Instagram Login**. This works for an Instagram professional account
(Business or Creator) and does not need a linked Facebook Page.

Instagram does not accept file uploads on this path. It downloads the video from a **public HTTPS URL**. Since
Clipper has no server, the export goes to your own S3-compatible bucket (Cloudflare R2 recommended) and Instagram
gets a presigned URL that is valid for one hour. The bucket stays private. The temporary object is always deleted
afterwards, whether publishing succeeds or fails.

### How a publish runs (`InstagramPublisher`)

1. **Local checks**, with nothing uploaded yet:
   - MP4/MOV, at most 300 MB, 3 s to 15 min long, at most 1920 px wide, aspect ratio between 0.01:1 and 10:1
     (9:16 recommended).
   - Visibility must be **public**, because Reels have no private or unlisted mode.
   - Caption checks (below). Every problem is reported in one `InstagramError.validation`.
2. **Token.** If the long-lived token is more than 50 days old, it is refreshed first. The 24 h publishing quota is
   checked (`GET /<IG_ID>/content_publishing_limit`).
3. **Upload** to `clipper-tmp/<uuid>/<file name>`. Files up to 100 MB go up in a single PUT. Larger files use
   multipart upload with 16 MiB parts, and the upload is aborted on failure.
4. **Create the container:** `POST https://graph.instagram.com/v25.0/<IG_ID>/media` with `media_type=REELS`,
   `video_url=<presigned GET>`, `caption`, `share_to_feed=true`.
5. **Wait for processing:** poll `GET /<container>?fields=status_code,status` until `FINISHED`.
   - `ERROR` or `EXPIRED` fails the publish.
   - Polling starts at 5 s and backs off to 30 s, with a 10 min timeout.
6. **Publish:** `POST /<IG_ID>/media_publish` with `creation_id`, then read the `permalink`.
7. **Clean up:** delete the temporary object. This always runs, including on failure or cancellation.

**Caption.** The caption is built as: title, description, `Music:` credits, then hashtags made from the tags.
- Limits: at most 2,200 characters, 30 hashtags and 20 @mentions.
- Credits are never dropped.
- If the caption is too long, the description is shortened first (ending in "…"), then the hashtag line is
  dropped, then the title is shortened.

### Credential keys

| Key | Value |
|---|---|
| `instagram.app_id` | Instagram app ID (from *Instagram → API setup with Instagram login*; this is not the Meta app ID) |
| `instagram.app_secret` | Instagram app secret. Only needed for the initial code exchange. |
| `instagram.redirect_uri` | The HTTPS redirect URI, exactly as registered (e.g. `https://localhost:8443/`) |
| `instagram.token` | JSON `InstagramToken`: `userID` (professional account id), `username`, `accessToken`, `issuedAt`, `expiresAt` |
| `storage.s3` | JSON `S3Config`: `endpoint`, `region`, `bucket`, `accessKeyID`, `secretAccessKey`, `pathStyle` |

### 1. Instagram account

- Switch the account to **Professional (Business or Creator)** in the Instagram app settings.
- No Facebook Page is required ([overview][ig-login]).

### 2. Meta developer app

These dashboard labels match Meta's docs as of October 2026. Meta renames menu items often.

1. At <https://developers.facebook.com/apps>, create an app of type **Business** ([get started][get-started]).
2. Add the **Instagram** product, then open **API setup with Instagram login**. This page shows the **Instagram app
   ID** and **Instagram app secret**. Store them as `instagram.app_id` and `instagram.app_secret`.
3. Under **Set up Instagram business login → Business login settings**, add an **OAuth redirect URI**.
   - The `redirect_uri` must *exactly match* a registered URI ([business login][business-login]).
   - Meta only accepts **HTTPS** redirect URIs, so the `http://127.0.0.1` loopback used for YouTube/TikTok does not
     work here.
   - Use something like `https://localhost:8443/`. Nothing has to listen on it (see step 4).
   - Store the same string as `instagram.redirect_uri`.
4. **Access level.** *Standard Access* is the default. It is meant for apps used only by people who have a role on
   the app ([overview][overview]).
   - For publishing to your own account, add that Instagram account to the app's roles (e.g. as an Instagram tester)
     and accept the invite in Instagram.
   - **App Review and Business Verification are only required for Advanced Access**, which you need only to serve
     accounts you don't own or manage ([overview][overview]).
   - Permissions requested: `instagram_business_basic` and `instagram_business_content_publish`. The older
     `business_*` scope names stopped working on 27 January 2025 ([business login][business-login]).

### 3. Connect (two options)

**A. Login flow (paste the redirected URL)**

1. `InstagramAuth.makeState()`, then `authorizeURL(state:)`. Open this URL in the browser: it is
   `https://www.instagram.com/oauth/authorize?client_id=…&redirect_uri=…&response_type=code&scope=…&state=…`.
2. Approve the request. Instagram redirects to your HTTPS redirect URI with `?code=…&state=…#_`. The browser shows a
   "can't connect" page, which is expected. **Copy the full URL from the address bar** and paste it into Clipper.
3. `connect(pastedRedirect:expectedState:)` then does the rest:
   - extracts the code and strips the trailing `#_`. The code is valid for 1 hour and can be used once.
   - checks `state`.
   - exchanges the code: `POST https://api.instagram.com/oauth/access_token` with the app secret. This returns a
     short-lived token valid for 1 h.
   - upgrades it: `GET https://graph.instagram.com/access_token?grant_type=ig_exchange_token`. This returns a
     long-lived token valid for 60 days.
   - reads the professional account id: `GET /me?fields=user_id,username`.
   - stores the result in `instagram.token`.

**B. Dashboard token (no OAuth at all)**

In *API setup with Instagram login → Generate access tokens*, add your account and generate a token. Dashboard
tokens are already long-lived (60 days) ([get started][get-started]). Then call
`InstagramAuth.storeDashboardToken(_:)`. The app secret and redirect URI are not needed for this option.

**Refresh.** Tokens are refreshed with `GET https://graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token`.
Meta only refreshes tokens that are at least 24 h old and not expired ([business login][business-login]). Clipper
refreshes automatically before a publish once the token is more than 50 days old. If the token has expired (no
publish for 60 days), log in again.

### 4. Cloudflare R2 bucket (temporary public URL)

1. In the Cloudflare dashboard, go to **R2 Object Storage** and create a bucket, e.g. `clipper-publish`. Leave it
   **private**: no public access and no custom domain is needed.
2. Go to **R2 → Manage API tokens → Create API token** ([R2 tokens][r2-tokens]).
   - Permission: **Object Read & Write**, scoped to this bucket.
   - Copy the **Access Key ID**, **Secret Access Key** and the endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.
     The secret is shown only once.
3. Store `storage.s3`:
   ```json
   {"endpoint": "https://<ACCOUNT_ID>.r2.cloudflarestorage.com", "region": "auto", "bucket": "clipper-publish",
    "accessKeyID": "…", "secretAccessKey": "…", "pathStyle": true}
   ```
   - R2 ignores the region, but SDKs require one; use `auto` ([presigned URLs][r2-presign]).
   - Presigned URLs can be valid for 1 s to 7 days.
   - Presigned URLs only work on the `r2.cloudflarestorage.com` S3 domain, not on custom domains.
4. Optional safety net: add an object lifecycle rule that deletes `clipper-tmp/` objects after 1 day.
   - Clipper deletes them itself; the rule only covers a crash mid-publish.
   - R2 also aborts incomplete multipart uploads after 7 days by default ([multipart][r2-multipart]).

**R2 free tier** (Standard storage, per month; [pricing][r2-pricing]):
- 10 GB-month of storage
- 1 million Class A operations (writes)
- 10 million Class B operations (reads)
- free egress

A Reel publish uses a handful of operations, and the object only exists for a few minutes.

**Other S3-compatible stores** work the same way:
- **AWS S3:** `https://s3.<region>.amazonaws.com` with the real region, and `pathStyle: false`.
- **MinIO:** e.g. `http://127.0.0.1:9000`. Instagram must be able to reach the URL from the internet, so a
  LAN-only MinIO won't work.
- **Backblaze B2:** `https://s3.<region>.backblazeb2.com`.

### Limits and notes

- **Publishing quota:** 100 API-published posts per 24 h moving window. Containers that are not published within
  24 h expire ([content publishing][publishing]).
- **Polling:** Meta suggests checking container status about once per minute for up to 5 minutes. Clipper polls
  faster at first (5 s, backing off to 30 s) so short Reels finish sooner. Change this with
  `InstagramPublisher.Options` if you prefer Meta's pace.
- **Reel spec** ([IG User Media reference][media-ref]):
  - MOV/MP4 with the moov atom at the front
  - HEVC or H.264, AAC audio at 48 kHz or less
  - 23–60 fps
  - at most 1920 px wide
  - 25 Mbps maximum video bitrate
  - 3 s – 15 min long
  - at most 300 MB
  - aspect ratio 0.01:1 – 10:1, with 9:16 recommended
- **Graph API version:** `v25.0` by default, the version used throughout Meta's docs in October 2026. Change it via
  `InstagramEndpoints(version:)`.

[ig-login]: https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login
[overview]: https://developers.facebook.com/docs/instagram-platform/overview
[get-started]: https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/get-started
[business-login]: https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/business-login
[publishing]: https://developers.facebook.com/docs/instagram-platform/content-publishing
[media-ref]: https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/media
[r2-tokens]: https://developers.cloudflare.com/r2/api/tokens/
[r2-presign]: https://developers.cloudflare.com/r2/api/s3/presigned-urls/
[r2-pricing]: https://developers.cloudflare.com/r2/pricing/
[r2-multipart]: https://developers.cloudflare.com/r2/objects/multipart-objects/

### Implementation references

- SigV4 is checked against the worked examples in the AWS docs:
  - [header-based auth][aws-header]: GET Object with Range, PUT Object, GET lifecycle, ListObjects
  - [presigned URL][aws-query]: the `examplebucket/test.txt` example with signature `aeeed9bb…f604d404`
- Code: `Packages/ClipperKit/Sources/ClipperPublish/Storage/` and `…/Instagram/`
- Tests: `Tests/ClipperPublishTests/S3Tests.swift` and `InstagramTests.swift`. These run against in-process mock
  servers only and never call Meta, Cloudflare or AWS.

[aws-header]: https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
[aws-query]: https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
