"""Fetch Yahoo Finance chart data for every ticker in index.html and write a JSON snapshot.

Run by the scheduled GitHub Action so the hosted page can read data same-origin-free
(via raw.githubusercontent.com) instead of going through a public CORS proxy.

Usage: python scripts/fetch_data.py <index.html> <out.json>
"""
import json
import re
import sys
import time
import urllib.error
import urllib.request

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
HOSTS = ['query1.finance.yahoo.com', 'query2.finance.yahoo.com']


def read_tickers(index_path):
    # COMPANIES in index.html is the single source of truth for the ticker list
    with open(index_path, encoding='utf-8') as f:
        return re.findall(r"ticker:\s*'(\w+)'", f.read())


def get_chart(ticker, rng):
    last_err = None
    for attempt in range(3):
        host = HOSTS[attempt % len(HOSTS)]
        url = (f'https://{host}/v8/finance/chart/{ticker}'
               f'?interval=1d&range={rng}&includePrePost=false')
        req = urllib.request.Request(url, headers={
            'User-Agent': UA,
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'en-US,en;q=0.9',
            'Referer': 'https://finance.yahoo.com/',
        })
        try:
            with urllib.request.urlopen(req, timeout=20) as res:
                result = json.load(res)['chart']['result'][0]
            # Keep only what the page reads: meta + daily closes
            quote = (result.get('indicators') or {}).get('quote') or [{}]
            return {'meta': result['meta'],
                    'indicators': {'quote': [{'close': quote[0].get('close') or []}]}}
        except (urllib.error.URLError, KeyError, IndexError, TypeError, ValueError) as err:
            last_err = err
            time.sleep(2 * (attempt + 1))
    print(f'[fetch] {ticker} ({rng}) failed: {last_err}', file=sys.stderr)
    return None


def main():
    index_path, out_path = sys.argv[1], sys.argv[2]
    tickers = read_tickers(index_path)
    data = {}
    for t in tickers:
        # 3mo gives the sparkline history; 1d gives the correct previous close (see +165% bug)
        entry = {'3mo': get_chart(t, '3mo'), '1d': get_chart(t, '1d')}
        if entry['3mo'] or entry['1d']:
            data[t] = entry
    print(f'[fetch] {len(data)}/{len(tickers)} tickers OK')
    if not data:
        sys.exit(1)  # keep the previous snapshot rather than publishing an empty one
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump({'updated': int(time.time() * 1000), 'tickers': data}, f, separators=(',', ':'))


if __name__ == '__main__':
    main()
