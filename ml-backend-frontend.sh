source env/bin/activate
sudo nohup streamlit run app.py --server.port=8000 --server.headless=true --server.address=0.0.0.0 > streamlit.log 2>&1 &