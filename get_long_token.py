import requests

APP_ID = "1422951465628516"
APP_SECRET = "4f47a4a0d7fb79d5c370f50f5ad8eb91"
SHORT_TOKEN = "EAAUOKrSkM2QBPUyIm0LMuN78ixcmCql8xcdqAumCYgalcEP93BEBSTtBXrZB76jAeK3aP75X38sjkIVrckJYAtnbyRw7RplPm2LQgwqeGcZBpg0XYlj1DwEuwzb6bxW8XtuZAZA8UnjwzIBYSGooodZBQbrSvZCIUlLYx4M8fxfsaC9M2cZCxtoGwMJZADhixgMwJzkDs8QYn0HmV5fbKMvZBaKzkfC6RAKS0EuQNkM6CnKL1YgZDZD"

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
