import os

from heatcal_proxy import main


if __name__ == "__main__":
    os.environ.setdefault("HEATCAL_PROXY_HOST", "0.0.0.0")
    os.environ.setdefault("HEATCAL_PROXY_PORT", os.getenv("PORT", "9000"))
    raise SystemExit(main())
