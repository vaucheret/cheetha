import requests
from dotenv import load_dotenv

load_dotenv()

APP_ID = os.getenv("APP_ID")
APP_SECRET = os.getenv("APP_SECRET")
SHORT_TOKEN = os.getenv("SHORT_TOKEN")

url = "https://graph.facebook.com/v20.0/oauth/access_token"

params = {
    "grant_type": "fb_exchange_token",
    "client_id": APP_ID,
    "client_secret": APP_SECRET,
    "fb_exchange_token": SHORT_TOKEN
}

response = requests.get(url, params=params)

if response.status_code == 200:
    data = response.json()
    print("✅ Nuevo token largo (60 días):")
    print(data["access_token"])
else:
    print("❌ Error:", response.status_code, response.text)
