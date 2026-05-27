#include <Arduino.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <Wire.h>
#include <math.h>

// Librarii pentru Bluetooth
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// Librarii pentru GPS
#include <TinyGPS++.h>
#include <HardwareSerial.h>

#include "model.h"  

Adafruit_MPU6050 mpu;
TinyGPSPlus gps;
HardwareSerial SerialGPS(2); // Folosim pinii 16 (RX2) si 17 (TX2)

// --- Setari BLE ---
BLEServer* pServer = NULL;
BLECharacteristic* pCrashCharacteristic = NULL; // Canal 1: Pentru Accident
BLECharacteristic* pGpsCharacteristic = NULL;   // Canal 2: Pentru Locatie GPS
bool deviceConnected = false;

#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CRASH_CHAR_UUID     "beb5483e-36e1-4688-b7f5-ea07361b26a8" // UUID-ul vechi
#define GPS_CHAR_UUID       "12345678-1234-5678-1234-56789abcdef0" // UUID-ul NOU pt GPS

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      Serial.println("--> Telefon conectat la casca!");
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      Serial.println("--> Telefon deconectat. Asteptam conexiuni...");
      pServer->getAdvertising()->start();
    }
};

// --- Setari Senzor si ML ---
const uint32_t SAMPLE_PERIOD_MS = 10; 
uint32_t lastSampleMs = 0;

static float magBuf[WINDOW_SIZE];
static uint16_t magIndex = 0;
static uint16_t sampleCountSinceLastEval = 0;

float logistic(float x) { return 1.0f / (1.0f + expf(-x)); }

void computeFeatures(float &mean_mag, float &std_mag, float &p2p_mag) {
    float tmp[WINDOW_SIZE];
    for (int i = 0; i < WINDOW_SIZE; i++) {
        int idx = (magIndex + i) % WINDOW_SIZE;
        tmp[i] = magBuf[idx];
    }
    float sum = 0.0f, minv = tmp[0], maxv = tmp[0];
    for (int i = 0; i < WINDOW_SIZE; i++) {
        float v = tmp[i];
        sum += v;
        if (v < minv) minv = v;
        if (v > maxv) maxv = v;
    }
    mean_mag = sum / WINDOW_SIZE;
    float varSum = 0.0f;
    for (int i = 0; i < WINDOW_SIZE; i++) {
        float d = tmp[i] - mean_mag;
        varSum += d * d;
    }
    std_mag = sqrtf(varSum / WINDOW_SIZE);
    p2p_mag = maxv - minv;
}

void setup() {
    Serial.begin(115200);
    delay(1000);

    // Initializare GPS
    SerialGPS.begin(9600, SERIAL_8N1, 16, 17);
    Serial.println("GPS Initializat pe pinii 16/17...");

    // Initializare MPU6050
    if (!mpu.begin()) {
        Serial.println("EROARE: MPU6050 nu a fost gasit!");
        while (true) { delay(1000); }
    }
    mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
    for (int i = 0; i < WINDOW_SIZE; i++) { magBuf[i] = 1.0f; }
    Serial.println("Senzor de soc Initializat...");

    // --- Initializare BLE ---
    Serial.println("Pornire modul Bluetooth...");
    BLEDevice::init("RideGuard_Helmet");
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new MyServerCallbacks());
    BLEService *pService = pServer->createService(SERVICE_UUID);

    // Canal 1: Alerta Accident
    pCrashCharacteristic = pService->createCharacteristic(
                            CRASH_CHAR_UUID,
                            BLECharacteristic::PROPERTY_READ   |
                            BLECharacteristic::PROPERTY_NOTIFY  |
                            BLECharacteristic::PROPERTY_WRITE
                          );
    pCrashCharacteristic->addDescriptor(new BLE2902());
    pCrashCharacteristic->setValue("0"); 

    // Canal 2: Coordonate GPS
    pGpsCharacteristic = pService->createCharacteristic(
                            GPS_CHAR_UUID,
                            BLECharacteristic::PROPERTY_READ   |
                            BLECharacteristic::PROPERTY_NOTIFY  |
                            BLECharacteristic::PROPERTY_WRITE
                          );
    pGpsCharacteristic->addDescriptor(new BLE2902());
    pGpsCharacteristic->setValue("0.0,0.0"); // Valoare initiala

    pService->start();
    BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);
    pAdvertising->setScanResponse(true);
    BLEDevice::startAdvertising();

    Serial.println("Sistem complet ONLINE! Poti conecta telefonul.");
}

void loop() {
    // ==========================================
    // 1. CITIRE DATE GPS & SPION RAW
    // ==========================================
    while (SerialGPS.available() > 0) {
        char c = SerialGPS.read();
        
        // SPION 1: Afisam pe laptop absolut tot ce scuipa NEO-6M
        Serial.print(c); 
        
        gps.encode(c);
    }

    // SPION 2: Verificam daca modulul GPS a format o locatie valida
    if (gps.location.isUpdated()) {
        float lat = gps.location.lat();
        float lng = gps.location.lng();
        
        String gpsData = String(lat, 6) + "," + String(lng, 6);
        
        // Afisam cu o sageata mare pe laptop ca sa vedem cand trimite pe Bluetooth
        Serial.println();
        Serial.print(">>> PREGATIT SA TRIMITA BLE: ");
        Serial.println(gpsData);

        if (deviceConnected) {
            pGpsCharacteristic->setValue(gpsData.c_str());
            pGpsCharacteristic->notify();
            Serial.println(">>> TRIMIS CU SUCCES CATRE TELEFON!");
        } else {
            Serial.println(">>> EROARE: Telefonul nu este conectat!");
        }
    }

    // ==========================================
    // 2. CITIRE DATE MPU6050 & MACHINE LEARNING
    // ==========================================
    uint32_t now = millis();
    if (now - lastSampleMs >= SAMPLE_PERIOD_MS) {
        lastSampleMs = now;
        sensors_event_t a, g, temp;
        mpu.getEvent(&a, &g, &temp);

        float ax = a.acceleration.x / 9.81;
        float ay = a.acceleration.y / 9.81;
        float az = a.acceleration.z / 9.81;
        float mag = sqrtf(ax*ax + ay*ay + az*az);

        magBuf[magIndex] = mag;
        magIndex = (magIndex + 1) % WINDOW_SIZE;
        sampleCountSinceLastEval++;

        if (sampleCountSinceLastEval >= STEP_SIZE) {
            sampleCountSinceLastEval = 0;
            float mean_mag, std_mag, p2p_mag;
            computeFeatures(mean_mag, std_mag, p2p_mag);

            float decision = ShakeModel::W0 + ShakeModel::W1 * mean_mag + 
                             ShakeModel::W2 * std_mag + ShakeModel::W3 * p2p_mag;
            float prob_shake = logistic(decision);

            if (prob_shake > 0.85f && p2p_mag > 2.5f) {
                Serial.println("\n[!!!] ACCIDENT DETECTAT [!!!]");
                
                if (deviceConnected) {
                    pCrashCharacteristic->setValue("1"); 
                    pCrashCharacteristic->notify();     
                    Serial.println("--> Alerta trimisa catre telefon!");
                    
                    delay(3000); 
                    
                    pCrashCharacteristic->setValue("0");
                    pCrashCharacteristic->notify();
                } else {
                    delay(3000);
                }
                
                for (int i = 0; i < WINDOW_SIZE; i++) { magBuf[i] = 1.0f; }
            }
        }
    }
}