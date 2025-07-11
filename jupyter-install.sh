#!/bin/bash
# Update package list and install Jupyter Notebook
apt update -y
apt-get upgrade -y
#create python3 virtual environment
apt install -y python3-venv
mkdir -p /home/ubuntu/jupyternotebook/
cp jupyter.service /home/ubuntu/jupyternotebook/
cp ml-backend-frontend.sh /home/ubuntu/jupyternotebook/
cp front-backend.py /home/ubuntu/jupyternotebook/
cd /home/ubuntu/jupyternotebook/

python3 -m venv env
source env/bin/activate
pip install --upgrade pip
# pip install -r requirements.txt
pip install jupyter
pip install numpy
pip install pandas
pip install matplotlib
pip install seaborn
pip install plotly-express
pip install isodate
pip install scikit-learn
pip install pytest-warnings
pip install joblib
pip install streamlit


# to start jupyter notebook
cp jupyter.service /etc/systemd/system/jupyter.service
systemctl enable jupyter.service
systemctl start jupyter.service

