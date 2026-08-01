# Credentials and access - EXAMPLE

Copy this to CREDENTIALS.md and fill it in. That file is gitignored; this one
is committed so a clone knows what it needs.

Nothing here is secret. Every value below is a placeholder.

THE SERVER is <machine name>, at <192.168.x.x> on the LAN.
Public name: <radio.example.org>


## What you have to create

Six credentials, in the order you will need them.

  1. A Windows (or Linux) service account to run everything as, so the
     services are not root/SYSTEM.
  2. An icecast source password - liquidsoap uses it to hand over the audio.
  3. An icecast admin password - for its own admin pages.
  4. A harbor password - what a live microphone connects with.
  5. A desk/talk password - guards the browser pages.
  6. A media server account, if you run one.


## Everything at a glance

  Talk - put your voice on air
    https://<radio.example.org>/talk/
    user  dj
    pass  <desk password>

  Mixing desk - live knobs, changeable while on air
    https://<radio.example.org>/interactive
    also embedded inside the talk page
    user  dj
    pass  <desk password>

  Live source - Cool Mic, butt, any icecast source client
    <192.168.x.x> port 8005, mount live
    user  source
    pass  <harbor password>

  Icecast admin - listener counts, kick a stuck source
    http://localhost:8000/admin/    <- from the server itself only, by default
    user  admin
    pass  <icecast admin password>

  Icecast source - what liquidsoap uses
    user  source
    pass  <icecast source password>

  Media server (Jellyfin), if you run one
    https://<music.example.org>
    user  <account>
    pass  <password>

  Service account
    .\<svc-account>
    pass  <service account password>

Public, no password:
  https://<radio.example.org>            the station page
  https://<radio.example.org>/stream     raw audio
  https://<radio.example.org>/next/      staging copy of the page
  https://<radio.example.org>/status-json.xsl   now playing


## Where each one is configured

  desk / talk
      A bcrypt hash in the Caddyfile, in the basic_auth blocks for /talk*,
      /interactive and /messages/voice/*. Generate it with:

          caddy hash-password --plaintext '<password>'

      The hash is safe to commit; the plaintext is not.

  harbor  and  icecast source
      NOT in radio.liq. Liquidsoap reads them from its service environment,
      which is what keeps radio.liq committable:

          RADIO_HARBOR_PASSWORD
          RADIO_ICECAST_PASSWORD

      On Windows those live in the service's Environment value under
      HKLM\SYSTEM\CurrentControlSet\Services\<service>. Elsewhere, set them
      however your init system does environment.

  icecast source (again) and icecast admin
      icecast.xml, which is gitignored because it holds them inline. Icecast
      cannot read them from the environment, which is the whole reason that
      file is not in the repo.

  service account
      However your OS creates local accounts. Grant it read on the music
      library and write on the log and cache directories, and nothing else.


## More than one DJ

Harbor takes one shared password by default. It also accepts an auth function,
so per-person credentials are a small change to radio.liq:

    def check(u) =
      if     u.user == "someone" then u.password == "..."
      elsif  u.user == "guest"   then u.password == "..."
      else false end
    end
    live = input.harbor("live", port = 8005, auth = check, ...)

Worth doing before handing the station to anyone else: one password per person
means one can be revoked without disturbing the others.


## Things deliberately not written down

  Cloud credentials for the ACME DNS challenge. Caddy reads them from its
  service environment. They are your account's keys, not ones made for this
  project - scope a dedicated user to just the one DNS zone if you can.

  Router admin.


## A warning worth inheriting

The icecast source protocol sends its password in clear text. Do not forward
harbor's port straight to the internet. Either keep it on the LAN, or put TLS
in front of it - and note that an ordinary HTTP reverse proxy will NOT work
for a live source, because icecast answers 200 before the upload finishes and
most proxies tear the request down at that point. Layer-4 TCP forwarding is
the approach that works.
