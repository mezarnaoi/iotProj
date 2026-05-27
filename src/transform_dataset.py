import pandas as pd
import numpy as np

def convert_kaggle_to_sparrow_format(input_csv, output_csv):
    df = pd.read_csv(input_csv, header=None)
    
    # 0: String (falling_right_hand), 1: ax, 2: ay, 3: az, 4: altceva
    
    # Extragem doar axele (coloanele 1, 2, 3)
    data = df[[1, 2, 3]].copy()
    
    # Redenumim coloanele
    data.columns = ['ax_g', 'ay_g', 'az_g']
    
    # Simulam milisecundele (100Hz = pas de 10ms), plecand de la 0
    data.insert(0, 'millis', np.arange(0, len(data) * 10, 10))
    
    # Adaugam label-ul de Accident/Crash (label = 1)
    data['label'] = 1
    
    # Salvam fisierul final fara header
    data.to_csv(output_csv, index=False, header=False)

if __name__ == "__main__":
    convert_kaggle_to_sparrow_format('input.csv', 'raw_data_label1.csv')
