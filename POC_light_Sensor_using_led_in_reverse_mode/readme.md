# BreakingBadUSB
##### [Código y esquemas charla BreakingBadUSB impartida en la H-CON por Rober y Jejo (usando un Attiny como MitM de un teclado USB). <br/> (H-C0N:Hackplayers Conference 2022)](https://www.h-c0n.com/p/ponencias2022.html#Charla_RobertoCasado_SergioBlazquez)

Esta parte al final no la introducimos en el prototipo final.
Pero su diseño me gusta tanto que no he podido evitar incluirla en la documentacion.

La idea es hacer un sensor de luz de bajo coste. (sin elementos especiales.)
Para ello aprovechamos una caracteristica curiosa de los diodos led. (cuando estan en inversa se comportan como un pequeño condensador.)
(inversa es cuando les aplicas tencion "al reves" de forma que el led no luce y el diodo tampoco conduce."

![](./curva_teorica_I-V_de_un_LED.png)


a diferencia de un diodo normal el semiconductor del led esta expuesto a la luz.
Y su comportamiento cambia en funcion de la luz que le incida.
En nuestro caso vamos a aprovechar esto para "medir la luz"
![](./LED_discharge_times.png) 


  
[Ver/descargar codigo](./POC_attach_interrupt_on_USB_pin_es.ino)
  
  ```cpp
  ```

___
<a href="http://euskalhack.org/">
<img src="https://euskalhack.org/images/EuskalHack_Logo.png" alt="Asociación de Seguridad Informática EuskalHack - " />
</a>
