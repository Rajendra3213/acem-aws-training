import streamlit as st
import joblib
import numpy as np

# Load the trained model
model = joblib.load('linear_model.pkl')

st.title("View Count Predictor 📊")
st.write("Predict video view count based on likes and comments.")

# Input fields
like_count = st.number_input("Enter Like Count", min_value=0, step=1)
comment_count = st.number_input("Enter Comment Count", min_value=0, step=1)

# Predict button
if st.button("Predict"):
    input_data = np.array([[like_count, comment_count]])
    prediction = model.predict(input_data)
    st.success(f"Predicted View Count: {int(prediction[0])}")
