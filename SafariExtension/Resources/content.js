(() => {
    const APP = "youtube://www.youtube.com";
    const DONE_KEY = "ytkace-open-in-app";

    // Turns a YouTube web URL into an app URL, or null for pages the app can't show.
    function appURL(href) {
        let url;
        try { url = new URL(href); } catch (e) { return null; }
        const host = url.hostname.replace(/^(www|m)\./, "");
        const parts = url.pathname.split("/").filter(Boolean);
        const query = url.searchParams;
        const keep = (names) => {
            const out = new URLSearchParams();
            for (const name of names) {
                const value = query.get(name);
                if (value) out.set(name, value);
            }
            const text = out.toString();
            return text ? "?" + text : "";
        };
        const watch = (id) => {
            const out = new URLSearchParams({ v: id });
            for (const name of ["t", "start", "list", "index"]) {
                const value = query.get(name);
                if (value) out.set(name, value);
            }
            return `${APP}/watch?${out}`;
        };
        const id = (value) => (value && /^[\w-]{6,}$/.test(value) ? value : null);

        if (host === "youtu.be") {
            return id(parts[0]) ? watch(parts[0]) : null;
        }
        if (host !== "youtube.com") return null;

        const first = parts[0] || "";
        if (first === "watch") return id(query.get("v")) ? watch(query.get("v")) : null;
        if (first === "shorts" || first === "live" || first === "clip") {
            return id(parts[1]) ? `${APP}/${first}/${parts[1]}${keep(["t"])}` : null;
        }
        if (first === "playlist") return query.get("list") ? `${APP}/playlist${keep(["list"])}` : null;
        if (first === "channel" || first === "c" || first === "user") {
            return parts[1] ? `${APP}/${parts.slice(0, 3).join("/")}` : null;
        }
        if (first.startsWith("@") && first.length > 1) {
            return `${APP}/${parts.slice(0, 2).join("/")}`;
        }
        return null;
    }

    // Only once per page per tab, so going back to Safari doesn't bounce again.
    // Keyed by the app URL since the site rewrites its own URL after loading.
    function seen(target) {
        try {
            const list = JSON.parse(sessionStorage.getItem(DONE_KEY) || "[]");
            if (list.includes(target)) return true;
            list.push(target);
            sessionStorage.setItem(DONE_KEY, JSON.stringify(list.slice(-50)));
        } catch (e) {}
        return false;
    }

    // Same page with a different timestamp counts as the same page.
    const pageKey = (target) => target.replace(/[?&](t|start)=[^&]*/g, "");

    let last = null;
    function check() {
        const target = appURL(location.href);
        if (!target) return;
        const key = pageKey(target);
        if (key === last) return;
        last = key;
        if (!seen(key)) location.href = target;
    }

    check();
    // The site changes pages without reloading.
    window.addEventListener("popstate", check);
    window.addEventListener("yt-navigate-finish", check);
    setInterval(check, 500);
})();
