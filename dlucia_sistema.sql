-- =====================================================================
-- Sistema web de D'Lucia Muebles y Decoraciones E.I.R.L.
-- Modelo físico de datos - MySQL 8.0 Community (motor InnoDB)
-- 35 tablas · Apartado 7.3 del proyecto
--
-- Zona horaria: la sentencia SET time_zone de abajo solo afecta a la
-- sesión que ejecuta este script. La aplicación Java (Spring Boot) fija la
-- zona horaria en cada conexión (application.properties:
-- spring.datasource.url=...?connectionTimeZone=-05:00&forceConnectionTimeZoneToSession=true),
-- de modo que DEFAULT CURRENT_TIMESTAMP registre la hora de Perú aunque
-- el servidor virtual (VPS) esté configurado en otra zona.
--
-- Ejecución: se ejecuta una sola vez, con el usuario dlucia_deploy, sobre
-- un servidor sin la base dlucia_sistema (las tablas no usan IF NOT EXISTS
-- para que un error de instalación no pase inadvertido). Requisitos previos:
--   1. log_bin_trust_function_creators = 1 en la configuración de MySQL, para
--      que dlucia_deploy pueda crear los disparadores con el registro binario
--      activo (sin ese parámetro, CREATE TRIGGER exige el privilegio SUPER).
--   2. La variable de sesión @hash_gerente con el hash bcrypt (costo 12) de la
--      contraseña temporal del gerente, generado en el momento de la instalación.
--      Este archivo no contiene ninguna contraseña ni ningún hash. Ejemplo:
--        mysql -u dlucia_deploy -p -e "SET @hash_gerente='<hash>'; SOURCE dlucia_sistema.sql;"
-- Si falta cualquiera de los dos, el script se detiene con un error y no deja
-- una instalación incompleta en uso.
--
-- Revisión (versión 3): disparadores obligatorios y verificados; contraseña
-- inicial fuera del script; FK compuestas venta/seguimiento -> cotizacion;
-- orden_produccion asociada al ítem del pedido (id_detalle_pedido).
-- =====================================================================
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS dlucia_sistema
  DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci;
USE dlucia_sistema;
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET time_zone = '-05:00';

-- Perfiles de acceso; contiene los seis roles definidos en R-02.
CREATE TABLE rol (
  id_rol                   INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del rol.',
  nombre                   VARCHAR(40) NOT NULL
    COMMENT 'Nombre del rol (p. ej., Gerente general, Vendedor).',
  descripcion              VARCHAR(150) NULL
    COMMENT 'Descripción de las funciones del rol.',
  CONSTRAINT pk_rol PRIMARY KEY (id_rol),
  CONSTRAINT uq_rol_nombre UNIQUE (nombre)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Perfiles de acceso; contiene los seis roles definidos en R-02.';

-- Acciones que pueden realizarse en cada módulo del sistema.
CREATE TABLE permiso (
  id_permiso               INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del permiso.',
  modulo                   VARCHAR(40) NOT NULL
    COMMENT 'Módulo de la Tabla 32 al que pertenece la acción.',
  accion                   VARCHAR(40) NOT NULL
    COMMENT 'Acción permitida (registrar, aprobar, anular, consultar, etc.).',
  CONSTRAINT pk_permiso PRIMARY KEY (id_permiso),
  CONSTRAINT uq_permiso_modulo_accion UNIQUE (modulo, accion)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Acciones que pueden realizarse en cada módulo del sistema.';

-- Tabla intermedia que asigna los permisos a cada rol (RF-48).
CREATE TABLE rol_permiso (
  id_rol                   INT UNSIGNED NOT NULL
    COMMENT 'Rol al que se concede el permiso.',
  id_permiso               INT UNSIGNED NOT NULL
    COMMENT 'Permiso concedido.',
  CONSTRAINT pk_rol_permiso PRIMARY KEY (id_rol, id_permiso),
  CONSTRAINT fk_rol_permiso_id_rol FOREIGN KEY (id_rol)
    REFERENCES rol (id_rol) ON UPDATE RESTRICT ON DELETE CASCADE,
  CONSTRAINT fk_rol_permiso_id_permiso FOREIGN KEY (id_permiso)
    REFERENCES permiso (id_permiso) ON UPDATE RESTRICT ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Tabla intermedia que asigna los permisos a cada rol (RF-48).';

-- Locales de Lima y Ayacucho en los que se ubica el stock y se registran las operaciones.
CREATE TABLE tienda (
  id_tienda                INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la tienda.',
  nombre                   VARCHAR(60) NOT NULL
    COMMENT 'Nombre de la tienda.',
  ciudad                   VARCHAR(40) NOT NULL
    COMMENT 'Ciudad en la que se ubica (Lima o Ayacucho).',
  direccion                VARCHAR(150) NOT NULL
    COMMENT 'Dirección del local.',
  CONSTRAINT pk_tienda PRIMARY KEY (id_tienda),
  CONSTRAINT uq_tienda_nombre UNIQUE (nombre)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Locales de Lima y Ayacucho en los que se ubica el stock y se registran las operaciones.';

-- Colaboradores con acceso al sistema (RF-45 a RF-47).
CREATE TABLE usuario (
  id_usuario               INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del usuario.',
  id_rol                   INT UNSIGNED NOT NULL
    COMMENT 'Rol asignado; determina las opciones visibles (P-10).',
  id_tienda                INT UNSIGNED NULL
    COMMENT 'Tienda en la que trabaja; nulo para el gerente general, que opera en ambas.',
  nombre_completo          VARCHAR(100) NOT NULL
    COMMENT 'Nombres y apellidos del colaborador.',
  nombre_usuario           VARCHAR(30) NOT NULL
    COMMENT 'Nombre con el que inicia sesión.',
  contrasena_hash          VARCHAR(255) NOT NULL
    COMMENT 'Hash bcrypt de la contraseña; nunca se guarda en texto legible (R-01).',
  estado                   ENUM('ACTIVO', 'BLOQUEADO', 'INACTIVO') NOT NULL DEFAULT 'ACTIVO'
    COMMENT 'Estado de la cuenta; BLOQUEADO tras tres intentos fallidos (R-01).',
  intentos_fallidos        TINYINT UNSIGNED NOT NULL DEFAULT 0
    COMMENT 'Intentos de inicio de sesión fallidos consecutivos.',
  debe_cambiar_contrasena  TINYINT(1) NOT NULL DEFAULT 1
    COMMENT 'Indica si debe cambiar la contraseña en el siguiente acceso (P-10).',
  fecha_creacion           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora de creación de la cuenta.',
  CONSTRAINT pk_usuario PRIMARY KEY (id_usuario),
  CONSTRAINT uq_usuario_nombre_usuario UNIQUE (nombre_usuario),
  CONSTRAINT fk_usuario_id_rol FOREIGN KEY (id_rol)
    REFERENCES rol (id_rol) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_usuario_id_tienda FOREIGN KEY (id_tienda)
    REFERENCES tienda (id_tienda) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_usuario_intentos CHECK (intentos_fallidos BETWEEN 0 AND 3)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Colaboradores con acceso al sistema (RF-45 a RF-47).';

-- Bitácora de las operaciones realizadas por cada usuario (RF-50 y RF-52).
CREATE TABLE registro_operacion (
  id_registro              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del registro; BIGINT por el alto volumen esperado.',
  id_usuario               INT UNSIGNED NOT NULL
    COMMENT 'Usuario que realizó la operación.',
  fecha_hora               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora de la operación.',
  modulo                   VARCHAR(40) NOT NULL
    COMMENT 'Módulo en el que se realizó la operación.',
  accion                   VARCHAR(40) NOT NULL
    COMMENT 'Acción realizada (crear, modificar, anular, aprobar, iniciar sesión).',
  entidad                  VARCHAR(40) NOT NULL
    COMMENT 'Nombre de la tabla afectada.',
  id_entidad               BIGINT UNSIGNED NOT NULL
    COMMENT 'Clave primaria del registro afectado.',
  detalle                  VARCHAR(300) NULL
    COMMENT 'Descripción breve o valores modificados.',
  CONSTRAINT pk_registro_operacion PRIMARY KEY (id_registro),
  CONSTRAINT fk_registro_operacion_id_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Bitácora de las operaciones realizadas por cada usuario (RF-50 y RF-52).';
CREATE INDEX idx_registro_usuario_fecha ON registro_operacion (id_usuario, fecha_hora);
CREATE INDEX idx_registro_entidad ON registro_operacion (entidad, id_entidad);

-- Artículos del catálogo de las dos líneas de negocio, incluidos telas e insumos (RF-01 y RF-02).
CREATE TABLE producto (
  id_producto              INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del producto.',
  codigo                   VARCHAR(20) NOT NULL
    COMMENT 'Código interno único del producto (R-03).',
  nombre                   VARCHAR(100) NOT NULL
    COMMENT 'Nombre comercial del producto.',
  categoria                VARCHAR(50) NOT NULL
    COMMENT 'Categoría (sofá, juego de comedor, tela, espuma, etc.).',
  linea_negocio            ENUM('MUEBLES', 'MATERIALES_TAPICERIA') NOT NULL
    COMMENT 'Línea de negocio a la que pertenece.',
  unidad_medida            ENUM('UNIDAD', 'METRO', 'KILOGRAMO', 'PLANCHA', 'JUEGO') NOT NULL
    COMMENT 'Unidad en la que se controla su stock.',
  stock_minimo             DECIMAL(10,2) NOT NULL DEFAULT 0
    COMMENT 'Cantidad por debajo de la cual se genera la alerta de reposición (RF-24).',
  activo                   TINYINT(1) NOT NULL DEFAULT 1
    COMMENT 'Indica si el producto está disponible para la venta (P-05).',
  CONSTRAINT pk_producto PRIMARY KEY (id_producto),
  CONSTRAINT uq_producto_codigo UNIQUE (codigo),
  CONSTRAINT chk_producto_stock_minimo CHECK (stock_minimo >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Artículos del catálogo de las dos líneas de negocio, incluidos telas e insumos (RF-01 y RF-02).';
CREATE INDEX idx_producto_nombre ON producto (nombre);
CREATE INDEX idx_producto_linea_categoria ON producto (linea_negocio, categoria);

-- Listas de precios con vigencia, aprobadas por el gerente general (RF-03 y P-01).
CREATE TABLE lista_precios (
  id_lista_precios         INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la lista de precios.',
  id_usuario_aprueba       INT UNSIGNED NULL
    COMMENT 'Gerente general que aprobó la lista; nulo mientras está en BORRADOR.',
  fecha_inicio_vigencia    DATE NOT NULL
    COMMENT 'Fecha desde la que rigen los precios.',
  fecha_fin_vigencia       DATE NULL
    COMMENT 'Fecha en que dejó de regir; nula mientras está vigente.',
  estado                   ENUM('BORRADOR', 'VIGENTE', 'HISTORICA') NOT NULL DEFAULT 'BORRADOR'
    COMMENT 'Situación de la lista; solo una puede estar VIGENTE.',
  fecha_aprobacion         DATETIME NULL
    COMMENT 'Fecha y hora de la aprobación.',
  marca_vigente            TINYINT GENERATED ALWAYS AS (IF(estado = 'VIGENTE', 1, NULL)) STORED NULL
    COMMENT 'Columna física auxiliar que, con su clave única, impide tener dos listas vigentes (R-04).',
  CONSTRAINT pk_lista_precios PRIMARY KEY (id_lista_precios),
  CONSTRAINT uq_lista_precios_vigente UNIQUE (marca_vigente),
  CONSTRAINT fk_lista_precios_id_usuario_aprueba FOREIGN KEY (id_usuario_aprueba)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_lista_vigencia CHECK (fecha_fin_vigencia IS NULL OR fecha_fin_vigencia >= fecha_inicio_vigencia),
  CONSTRAINT chk_lista_aprobacion CHECK (estado = 'BORRADOR' OR (id_usuario_aprueba IS NOT NULL AND fecha_aprobacion IS NOT NULL)),
  CONSTRAINT chk_lista_fin CHECK ((estado = 'HISTORICA') = (fecha_fin_vigencia IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Listas de precios con vigencia, aprobadas por el gerente general (RF-03 y P-01).';

-- Precio de venta de cada producto dentro de una lista (RF-03).
CREATE TABLE detalle_lista_precios (
  id_lista_precios         INT UNSIGNED NOT NULL
    COMMENT 'Lista a la que pertenece el precio.',
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Producto al que se asigna el precio.',
  precio_venta             DECIMAL(10,2) NOT NULL
    COMMENT 'Precio de venta en soles, con IGV incluido.',
  CONSTRAINT pk_detalle_lista_precios PRIMARY KEY (id_lista_precios, id_producto),
  CONSTRAINT fk_detalle_lista_precios_id_lista_precios FOREIGN KEY (id_lista_precios)
    REFERENCES lista_precios (id_lista_precios) ON UPDATE RESTRICT ON DELETE CASCADE,
  CONSTRAINT fk_detalle_lista_precios_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_dlp_precio CHECK (precio_venta > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Precio de venta de cada producto dentro de una lista (RF-03).';

-- Metas de ventas por tienda, línea de negocio y mes (RF-07).
CREATE TABLE meta_comercial (
  id_meta                  INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la meta.',
  id_tienda                INT UNSIGNED NOT NULL
    COMMENT 'Tienda a la que se asigna la meta.',
  anio                     SMALLINT UNSIGNED NOT NULL
    COMMENT 'Año de la meta.',
  mes                      TINYINT UNSIGNED NOT NULL
    COMMENT 'Mes de la meta.',
  linea_negocio            ENUM('MUEBLES', 'MATERIALES_TAPICERIA') NOT NULL
    COMMENT 'Línea de negocio de la meta.',
  monto_meta               DECIMAL(12,2) NOT NULL
    COMMENT 'Monto de ventas esperado en soles.',
  CONSTRAINT pk_meta_comercial PRIMARY KEY (id_meta),
  CONSTRAINT uq_meta_tienda_periodo_linea UNIQUE (id_tienda, anio, mes, linea_negocio),
  CONSTRAINT fk_meta_comercial_id_tienda FOREIGN KEY (id_tienda)
    REFERENCES tienda (id_tienda) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_meta_anio CHECK (anio >= 2025),
  CONSTRAINT chk_meta_mes CHECK (mes BETWEEN 1 AND 12),
  CONSTRAINT chk_meta_monto CHECK (monto_meta > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Metas de ventas por tienda, línea de negocio y mes (RF-07).';

-- Existencia y cantidad reservada de cada producto en cada tienda (RF-06 y RF-09).
CREATE TABLE stock (
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Producto controlado.',
  id_tienda                INT UNSIGNED NOT NULL
    COMMENT 'Tienda en la que se encuentra.',
  existencia               DECIMAL(10,2) NOT NULL DEFAULT 0
    COMMENT 'Cantidad física en la tienda; se actualiza con cada movimiento.',
  cantidad_reservada       DECIMAL(10,2) NOT NULL DEFAULT 0
    COMMENT 'Cantidad comprometida para órdenes de producción (R-08).',
  ubicacion                VARCHAR(60) NULL
    COMMENT 'Ubicación dentro del local (exhibición, almacén, estante).',
  CONSTRAINT pk_stock PRIMARY KEY (id_producto, id_tienda),
  CONSTRAINT fk_stock_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_stock_id_tienda FOREIGN KEY (id_tienda)
    REFERENCES tienda (id_tienda) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_stock_existencia CHECK (existencia >= 0),
  CONSTRAINT chk_stock_reserva CHECK (cantidad_reservada >= 0 AND cantidad_reservada <= existencia)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Existencia y cantidad reservada de cada producto en cada tienda (RF-06 y RF-09).';

-- Envíos de productos de una tienda a otra (RF-37).
CREATE TABLE traslado (
  id_traslado              INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del traslado.',
  id_tienda_origen         INT UNSIGNED NOT NULL
    COMMENT 'Tienda que envía los productos.',
  id_tienda_destino        INT UNSIGNED NOT NULL
    COMMENT 'Tienda que recibe los productos; distinta de la de origen.',
  id_usuario               INT UNSIGNED NOT NULL
    COMMENT 'Usuario que registró el envío en la tienda de origen.',
  id_usuario_recibe        INT UNSIGNED NULL
    COMMENT 'Usuario que confirmó la recepción en la tienda de destino.',
  fecha_hora               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora de envío (TRASLADO_SALIDA).',
  estado                   ENUM('EN_TRANSITO', 'RECIBIDO') NOT NULL DEFAULT 'EN_TRANSITO'
    COMMENT 'EN_TRANSITO desde el envío; RECIBIDO cuando el destino confirma la llegada.',
  fecha_recepcion          DATETIME NULL
    COMMENT 'Fecha y hora de recepción (TRASLADO_INGRESO).',
  observacion              VARCHAR(200) NULL
    COMMENT 'Observaciones del envío o de la recepción.',
  CONSTRAINT pk_traslado PRIMARY KEY (id_traslado),
  CONSTRAINT fk_traslado_id_tienda_origen FOREIGN KEY (id_tienda_origen)
    REFERENCES tienda (id_tienda) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_traslado_id_tienda_destino FOREIGN KEY (id_tienda_destino)
    REFERENCES tienda (id_tienda) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_traslado_id_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_traslado_id_usuario_recibe FOREIGN KEY (id_usuario_recibe)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_traslado_tiendas CHECK (id_tienda_origen <> id_tienda_destino),
  CONSTRAINT chk_traslado_recepcion CHECK (estado = 'EN_TRANSITO' OR (fecha_recepcion IS NOT NULL AND id_usuario_recibe IS NOT NULL AND fecha_recepcion >= fecha_hora))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Envíos de productos de una tienda a otra (RF-37).';
CREATE INDEX idx_traslado_estado ON traslado (estado, id_tienda_destino);

-- Productos y cantidades incluidos en un traslado.
CREATE TABLE detalle_traslado (
  id_traslado              INT UNSIGNED NOT NULL
    COMMENT 'Traslado al que pertenece.',
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Producto trasladado.',
  cantidad                 DECIMAL(10,2) NOT NULL
    COMMENT 'Cantidad trasladada.',
  CONSTRAINT pk_detalle_traslado PRIMARY KEY (id_traslado, id_producto),
  CONSTRAINT fk_detalle_traslado_id_traslado FOREIGN KEY (id_traslado)
    REFERENCES traslado (id_traslado) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_detalle_traslado_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_dt_cantidad CHECK (cantidad > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Productos y cantidades incluidos en un traslado.';

-- Empresas o personas que abastecen productos e insumos (RF-17).
CREATE TABLE proveedor (
  id_proveedor             INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del proveedor.',
  ruc                      CHAR(11) NOT NULL
    COMMENT 'RUC del proveedor (R-09 y R-10).',
  razon_social             VARCHAR(120) NOT NULL
    COMMENT 'Razón social o nombre del proveedor.',
  telefono                 VARCHAR(15) NOT NULL
    COMMENT 'Teléfono de contacto.',
  correo                   VARCHAR(100) NULL
    COMMENT 'Correo electrónico de contacto.',
  direccion                VARCHAR(150) NULL
    COMMENT 'Dirección fiscal o de despacho.',
  activo                   TINYINT(1) NOT NULL DEFAULT 1
    COMMENT 'Indica si se le pueden emitir órdenes de compra.',
  CONSTRAINT pk_proveedor PRIMARY KEY (id_proveedor),
  CONSTRAINT uq_proveedor_ruc UNIQUE (ruc),
  CONSTRAINT chk_proveedor_ruc CHECK (ruc REGEXP '^[0-9]{11}$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Empresas o personas que abastecen productos e insumos (RF-17).';
CREATE INDEX idx_proveedor_razon_social ON proveedor (razon_social);

-- Tabla intermedia con los productos que abastece cada proveedor (RF-17).
CREATE TABLE proveedor_producto (
  id_proveedor             INT UNSIGNED NOT NULL
    COMMENT 'Proveedor.',
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Producto que abastece.',
  precio_referencial       DECIMAL(10,2) NULL
    COMMENT 'Último precio de compra conocido.',
  CONSTRAINT pk_proveedor_producto PRIMARY KEY (id_proveedor, id_producto),
  CONSTRAINT fk_proveedor_producto_id_proveedor FOREIGN KEY (id_proveedor)
    REFERENCES proveedor (id_proveedor) ON UPDATE RESTRICT ON DELETE CASCADE,
  CONSTRAINT fk_proveedor_producto_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE CASCADE,
  CONSTRAINT chk_pp_precio CHECK (precio_referencial IS NULL OR precio_referencial > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Tabla intermedia con los productos que abastece cada proveedor (RF-17).';

-- Órdenes de compra emitidas a los proveedores y aprobadas por el gerente general (RF-18).
CREATE TABLE orden_compra (
  id_orden_compra          INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la orden de compra.',
  numero                   VARCHAR(15) NOT NULL
    COMMENT 'Número correlativo de la orden (p. ej., OC-2026-0001).',
  id_proveedor             INT UNSIGNED NOT NULL
    COMMENT 'Proveedor al que se emite.',
  id_tienda                INT UNSIGNED NOT NULL
    COMMENT 'Tienda que recibirá la mercadería.',
  id_usuario_registra      INT UNSIGNED NOT NULL
    COMMENT 'Usuario que elaboró la orden.',
  id_usuario_aprueba       INT UNSIGNED NULL
    COMMENT 'Gerente general que la aprobó (R-02).',
  fecha_emision            DATE NOT NULL
    COMMENT 'Fecha de emisión.',
  fecha_aprobacion         DATETIME NULL
    COMMENT 'Fecha y hora de la aprobación.',
  estado                   ENUM('REGISTRADA', 'APROBADA', 'RECIBIDA_PARCIAL', 'RECIBIDA', 'ANULADA') NOT NULL DEFAULT 'REGISTRADA'
    COMMENT 'Situación de la orden.',
  total                    DECIMAL(12,2) NOT NULL DEFAULT 0
    COMMENT 'Importe total; suma de los subtotales del detalle.',
  CONSTRAINT pk_orden_compra PRIMARY KEY (id_orden_compra),
  CONSTRAINT uq_orden_compra_numero UNIQUE (numero),
  CONSTRAINT fk_orden_compra_id_proveedor FOREIGN KEY (id_proveedor)
    REFERENCES proveedor (id_proveedor) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_orden_compra_id_tienda FOREIGN KEY (id_tienda)
    REFERENCES tienda (id_tienda) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_orden_compra_id_usuario_registra FOREIGN KEY (id_usuario_registra)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_orden_compra_id_usuario_aprueba FOREIGN KEY (id_usuario_aprueba)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_oc_total CHECK (total >= 0),
  CONSTRAINT chk_oc_aprobacion CHECK (estado IN ('REGISTRADA','ANULADA') OR (id_usuario_aprueba IS NOT NULL AND fecha_aprobacion IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Órdenes de compra emitidas a los proveedores y aprobadas por el gerente general (RF-18).';
CREATE INDEX idx_oc_estado_fecha ON orden_compra (estado, fecha_emision);

-- Productos, cantidades y precios acordados en cada orden de compra.
CREATE TABLE detalle_orden_compra (
  id_detalle_oc            INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del ítem de la orden.',
  id_orden_compra          INT UNSIGNED NOT NULL
    COMMENT 'Orden a la que pertenece.',
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Producto solicitado.',
  cantidad_solicitada      DECIMAL(10,2) NOT NULL
    COMMENT 'Cantidad pedida al proveedor.',
  precio_unitario          DECIMAL(10,2) NOT NULL
    COMMENT 'Precio de compra pactado.',
  subtotal                 DECIMAL(12,2) GENERATED ALWAYS AS (ROUND(cantidad_solicitada * precio_unitario, 2)) STORED NOT NULL
    COMMENT 'Importe del ítem; lo calcula MySQL y no puede editarse.',
  CONSTRAINT pk_detalle_orden_compra PRIMARY KEY (id_detalle_oc),
  CONSTRAINT uq_doc_orden_producto UNIQUE (id_orden_compra, id_producto),
  CONSTRAINT fk_detalle_orden_compra_id_orden_compra FOREIGN KEY (id_orden_compra)
    REFERENCES orden_compra (id_orden_compra) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_detalle_orden_compra_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_doc_cantidad CHECK (cantidad_solicitada > 0),
  CONSTRAINT chk_doc_precio CHECK (precio_unitario >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Productos, cantidades y precios acordados en cada orden de compra.';

-- Recepciones de mercadería de una orden de compra con su guía de remisión (RF-19).
CREATE TABLE recepcion_mercaderia (
  id_recepcion             INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la recepción.',
  id_orden_compra          INT UNSIGNED NOT NULL
    COMMENT 'Orden de compra recibida.',
  id_usuario               INT UNSIGNED NOT NULL
    COMMENT 'Usuario que recibió y verificó la mercadería.',
  fecha_hora               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora de la recepción.',
  numero_guia_remision     VARCHAR(20) NOT NULL
    COMMENT 'Número de la guía de remisión del proveedor (P-04).',
  conforme                 TINYINT(1) NOT NULL DEFAULT 1
    COMMENT 'Indica si toda la mercadería llegó conforme.',
  CONSTRAINT pk_recepcion_mercaderia PRIMARY KEY (id_recepcion),
  CONSTRAINT fk_recepcion_mercaderia_id_orden_compra FOREIGN KEY (id_orden_compra)
    REFERENCES orden_compra (id_orden_compra) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_recepcion_mercaderia_id_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Recepciones de mercadería de una orden de compra con su guía de remisión (RF-19).';

-- Cantidad recibida y cantidad conforme de cada ítem de la orden (P-04).
CREATE TABLE detalle_recepcion (
  id_detalle_recepcion     INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del ítem recibido.',
  id_recepcion             INT UNSIGNED NOT NULL
    COMMENT 'Recepción a la que pertenece.',
  id_detalle_oc            INT UNSIGNED NOT NULL
    COMMENT 'Ítem de la orden de compra que se recibe.',
  cantidad_recibida        DECIMAL(10,2) NOT NULL
    COMMENT 'Cantidad que llegó físicamente.',
  cantidad_conforme        DECIMAL(10,2) NOT NULL
    COMMENT 'Cantidad aceptada; es la única que genera INGRESO_COMPRA.',
  CONSTRAINT pk_detalle_recepcion PRIMARY KEY (id_detalle_recepcion),
  CONSTRAINT uq_dr_recepcion_item UNIQUE (id_recepcion, id_detalle_oc),
  CONSTRAINT fk_detalle_recepcion_id_recepcion FOREIGN KEY (id_recepcion)
    REFERENCES recepcion_mercaderia (id_recepcion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_detalle_recepcion_id_detalle_oc FOREIGN KEY (id_detalle_oc)
    REFERENCES detalle_orden_compra (id_detalle_oc) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_dr_cantidades CHECK (cantidad_recibida >= 0 AND cantidad_conforme >= 0 AND cantidad_conforme <= cantidad_recibida)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Cantidad recibida y cantidad conforme de cada ítem de la orden (P-04).';

-- Faltantes o productos observados durante la recepción (RF-20).
CREATE TABLE incidencia_recepcion (
  id_incidencia            INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la incidencia.',
  id_recepcion             INT UNSIGNED NOT NULL
    COMMENT 'Recepción en la que se detectó.',
  id_detalle_oc            INT UNSIGNED NOT NULL
    COMMENT 'Ítem de la orden afectado.',
  tipo                     ENUM('FALTANTE', 'PRODUCTO_OBSERVADO') NOT NULL
    COMMENT 'Tipo de incidencia.',
  cantidad                 DECIMAL(10,2) NOT NULL
    COMMENT 'Cantidad faltante u observada.',
  descripcion              VARCHAR(200) NOT NULL
    COMMENT 'Detalle de lo observado.',
  estado                   ENUM('ABIERTA', 'EN_DEVOLUCION', 'CERRADA') NOT NULL DEFAULT 'ABIERTA'
    COMMENT 'Situación de la incidencia ante el proveedor.',
  CONSTRAINT pk_incidencia_recepcion PRIMARY KEY (id_incidencia),
  CONSTRAINT fk_incidencia_recepcion_id_recepcion FOREIGN KEY (id_recepcion)
    REFERENCES recepcion_mercaderia (id_recepcion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_incidencia_recepcion_id_detalle_oc FOREIGN KEY (id_detalle_oc)
    REFERENCES detalle_orden_compra (id_detalle_oc) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_inc_cantidad CHECK (cantidad > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Faltantes o productos observados durante la recepción (RF-20).';

-- Clientes y potenciales clientes, diferenciados por su clasificación (RF-38 a RF-40).
CREATE TABLE cliente (
  id_cliente               INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del cliente.',
  clasificacion            ENUM('POTENCIAL', 'CLIENTE') NOT NULL DEFAULT 'POTENCIAL'
    COMMENT 'POTENCIAL hasta su primera compra; luego, CLIENTE (P-09).',
  tipo_documento           ENUM('DNI', 'RUC') NULL
    COMMENT 'Tipo de documento de identidad.',
  numero_documento         VARCHAR(11) NULL
    COMMENT 'Número de DNI o RUC (R-09 y R-10).',
  nombres_razon_social     VARCHAR(120) NOT NULL
    COMMENT 'Nombres y apellidos, o razón social.',
  telefono                 VARCHAR(15) NOT NULL
    COMMENT 'Teléfono de contacto; puede repetirse entre clientes con documento (familiares, empresa y representante).',
  correo                   VARCHAR(100) NULL
    COMMENT 'Correo electrónico.',
  direccion                VARCHAR(150) NULL
    COMMENT 'Dirección de domicilio o de entrega habitual.',
  fecha_registro           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora de registro.',
  activo                   TINYINT(1) NOT NULL DEFAULT 1
    COMMENT 'Indica si el registro está vigente.',
  telefono_sin_documento   VARCHAR(15) GENERATED ALWAYS AS (IF(numero_documento IS NULL, telefono, NULL)) STORED NULL
    COMMENT 'Columna física auxiliar: hace único el teléfono solo entre los registros sin documento (R-09 y CA-30).',
  CONSTRAINT pk_cliente PRIMARY KEY (id_cliente),
  CONSTRAINT uq_cliente_documento UNIQUE (numero_documento),
  CONSTRAINT uq_cliente_telefono_sin_doc UNIQUE (telefono_sin_documento),
  CONSTRAINT chk_cliente_tipo_numero CHECK ((tipo_documento IS NULL) = (numero_documento IS NULL)),
  CONSTRAINT chk_cliente_documento CHECK (clasificacion = 'POTENCIAL' OR (tipo_documento IS NOT NULL AND numero_documento IS NOT NULL)),
  CONSTRAINT chk_cliente_formato_doc CHECK (numero_documento IS NULL OR (tipo_documento = 'DNI' AND numero_documento REGEXP '^[0-9]{8}$') OR (tipo_documento = 'RUC' AND numero_documento REGEXP '^[0-9]{11}$'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Clientes y potenciales clientes, diferenciados por su clasificación (RF-38 a RF-40).';
CREATE INDEX idx_cliente_nombre ON cliente (nombres_razon_social);
CREATE INDEX idx_cliente_telefono ON cliente (telefono);
CREATE INDEX idx_cliente_clasificacion ON cliente (clasificacion, fecha_registro);

-- Propuestas de precios entregadas a los clientes (RF-10).
CREATE TABLE cotizacion (
  id_cotizacion            INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la cotización.',
  numero                   VARCHAR(15) NOT NULL
    COMMENT 'Número correlativo de la cotización.',
  id_cliente               INT UNSIGNED NOT NULL
    COMMENT 'Cliente o potencial cliente cotizado.',
  id_usuario               INT UNSIGNED NOT NULL
    COMMENT 'Vendedor que la elaboró.',
  id_tienda                INT UNSIGNED NOT NULL
    COMMENT 'Tienda en la que se emitió.',
  fecha                    DATE NOT NULL
    COMMENT 'Fecha de emisión.',
  fecha_validez            DATE NOT NULL
    COMMENT 'Fecha hasta la que se respetan los precios.',
  estado                   ENUM('VIGENTE', 'VENCIDA', 'ACEPTADA') NOT NULL DEFAULT 'VIGENTE'
    COMMENT 'Situación de la cotización.',
  total                    DECIMAL(12,2) NOT NULL
    COMMENT 'Importe total cotizado.',
  CONSTRAINT pk_cotizacion PRIMARY KEY (id_cotizacion),
  CONSTRAINT uq_cotizacion_numero UNIQUE (numero),
  CONSTRAINT uq_cotizacion_cliente UNIQUE (id_cotizacion, id_cliente),
  CONSTRAINT fk_cotizacion_id_cliente FOREIGN KEY (id_cliente)
    REFERENCES cliente (id_cliente) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_cotizacion_id_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_cotizacion_id_tienda FOREIGN KEY (id_tienda)
    REFERENCES tienda (id_tienda) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_cot_validez CHECK (fecha_validez >= fecha),
  CONSTRAINT chk_cot_total CHECK (total >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Propuestas de precios entregadas a los clientes (RF-10).';
CREATE INDEX idx_cotizacion_estado_validez ON cotizacion (estado, fecha_validez);

-- Productos, cantidades y precios incluidos en cada cotización.
CREATE TABLE detalle_cotizacion (
  id_cotizacion            INT UNSIGNED NOT NULL
    COMMENT 'Cotización a la que pertenece.',
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Producto cotizado.',
  cantidad                 DECIMAL(10,2) NOT NULL
    COMMENT 'Cantidad cotizada.',
  precio_unitario          DECIMAL(10,2) NOT NULL
    COMMENT 'Precio copiado de la lista VIGENTE (R-04).',
  subtotal                 DECIMAL(12,2) GENERATED ALWAYS AS (ROUND(cantidad * precio_unitario, 2)) STORED NOT NULL
    COMMENT 'Importe del ítem; lo calcula MySQL y no puede editarse.',
  CONSTRAINT pk_detalle_cotizacion PRIMARY KEY (id_cotizacion, id_producto),
  CONSTRAINT fk_detalle_cotizacion_id_cotizacion FOREIGN KEY (id_cotizacion)
    REFERENCES cotizacion (id_cotizacion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_detalle_cotizacion_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_dc_cantidad CHECK (cantidad > 0),
  CONSTRAINT chk_dc_precio CHECK (precio_unitario >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Productos, cantidades y precios incluidos en cada cotización.';

-- Acciones de seguimiento a los potenciales clientes (RF-41).
CREATE TABLE seguimiento (
  id_seguimiento           INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del seguimiento.',
  id_cliente               INT UNSIGNED NOT NULL
    COMMENT 'Cliente al que se realiza el seguimiento.',
  id_usuario               INT UNSIGNED NOT NULL
    COMMENT 'Vendedor que lo realizó.',
  id_cotizacion            INT UNSIGNED NULL
    COMMENT 'Cotización a la que se refiere, si existe; debe ser del mismo cliente.',
  fecha_hora               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora del contacto.',
  accion                   VARCHAR(150) NOT NULL
    COMMENT 'Acción realizada (llamada, mensaje, visita).',
  resultado                VARCHAR(200) NULL
    COMMENT 'Resultado obtenido.',
  fecha_proxima_gestion    DATE NULL
    COMMENT 'Fecha programada para el siguiente contacto.',
  CONSTRAINT pk_seguimiento PRIMARY KEY (id_seguimiento),
  CONSTRAINT fk_seguimiento_id_cliente FOREIGN KEY (id_cliente)
    REFERENCES cliente (id_cliente) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_seguimiento_id_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_seguimiento_cotizacion_cliente FOREIGN KEY (id_cotizacion, id_cliente)
    REFERENCES cotizacion (id_cotizacion, id_cliente) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Acciones de seguimiento a los potenciales clientes (RF-41).';
CREATE INDEX idx_seguimiento_proxima ON seguimiento (fecha_proxima_gestion);

-- Operaciones de venta concretadas en una tienda (RF-11).
CREATE TABLE venta (
  id_venta                 INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la venta.',
  numero                   VARCHAR(15) NOT NULL
    COMMENT 'Número correlativo interno de la venta.',
  id_cliente               INT UNSIGNED NOT NULL
    COMMENT 'Cliente que compra.',
  id_usuario               INT UNSIGNED NOT NULL
    COMMENT 'Vendedor que registró la venta.',
  id_tienda                INT UNSIGNED NOT NULL
    COMMENT 'Tienda en la que se realizó.',
  id_cotizacion            INT UNSIGNED NULL
    COMMENT 'Cotización que la originó; debe ser del mismo cliente y genera como máximo una venta.',
  fecha_hora               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora de la venta.',
  total                    DECIMAL(12,2) NOT NULL
    COMMENT 'Importe total con IGV; suma de los subtotales del detalle.',
  tasa_igv                 DECIMAL(5,2) NOT NULL DEFAULT 18.00
    COMMENT 'Tasa del IGV aplicada, en porcentaje; se guarda por si la tasa legal cambia.',
  op_gravada               DECIMAL(12,2) GENERATED ALWAYS AS (ROUND(total / (1 + tasa_igv / 100), 2)) STORED NOT NULL
    COMMENT 'Valor sin IGV (operación gravada).',
  igv                      DECIMAL(12,2) GENERATED ALWAYS AS (total - op_gravada) STORED NOT NULL
    COMMENT 'Importe del IGV incluido en el precio.',
  estado                   ENUM('CONCRETADA', 'ANULADA') NOT NULL DEFAULT 'CONCRETADA'
    COMMENT 'Situación de la venta; las ventas no se eliminan, se anulan.',
  id_usuario_anula         INT UNSIGNED NULL
    COMMENT 'Gerente general que autorizó la anulación.',
  fecha_anulacion          DATETIME NULL
    COMMENT 'Fecha y hora de la anulación.',
  motivo_anulacion         VARCHAR(200) NULL
    COMMENT 'Motivo de la anulación; los productos vuelven al stock con REINGRESO_ANULACION.',
  CONSTRAINT pk_venta PRIMARY KEY (id_venta),
  CONSTRAINT uq_venta_numero UNIQUE (numero),
  CONSTRAINT uq_venta_cotizacion UNIQUE (id_cotizacion),
  CONSTRAINT fk_venta_id_cliente FOREIGN KEY (id_cliente)
    REFERENCES cliente (id_cliente) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_venta_id_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_venta_id_tienda FOREIGN KEY (id_tienda)
    REFERENCES tienda (id_tienda) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_venta_cotizacion_cliente FOREIGN KEY (id_cotizacion, id_cliente)
    REFERENCES cotizacion (id_cotizacion, id_cliente) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_venta_id_usuario_anula FOREIGN KEY (id_usuario_anula)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_venta_total CHECK (total >= 0),
  CONSTRAINT chk_venta_tasa_igv CHECK (tasa_igv BETWEEN 0 AND 100),
  CONSTRAINT chk_venta_anulacion CHECK (estado <> 'ANULADA' OR (id_usuario_anula IS NOT NULL AND fecha_anulacion IS NOT NULL AND motivo_anulacion IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Operaciones de venta concretadas en una tienda (RF-11).';
CREATE INDEX idx_venta_tienda_fecha ON venta (id_tienda, fecha_hora);
CREATE INDEX idx_venta_fecha ON venta (fecha_hora);

-- Productos, cantidades y precios vendidos.
CREATE TABLE detalle_venta (
  id_detalle_venta         INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del ítem vendido.',
  id_venta                 INT UNSIGNED NOT NULL
    COMMENT 'Venta a la que pertenece.',
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Producto vendido.',
  cantidad                 DECIMAL(10,2) NOT NULL
    COMMENT 'Cantidad vendida.',
  precio_unitario          DECIMAL(10,2) NOT NULL
    COMMENT 'Precio copiado de la lista VIGENTE; no editable (R-04).',
  subtotal                 DECIMAL(12,2) GENERATED ALWAYS AS (ROUND(cantidad * precio_unitario, 2)) STORED NOT NULL
    COMMENT 'Importe del ítem; lo calcula MySQL y no puede editarse.',
  CONSTRAINT pk_detalle_venta PRIMARY KEY (id_detalle_venta),
  CONSTRAINT uq_dv_venta_producto UNIQUE (id_venta, id_producto),
  CONSTRAINT fk_detalle_venta_id_venta FOREIGN KEY (id_venta)
    REFERENCES venta (id_venta) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_detalle_venta_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_dv_cantidad CHECK (cantidad > 0),
  CONSTRAINT chk_dv_precio CHECK (precio_unitario >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Productos, cantidades y precios vendidos.';

-- Pagos totales, adelantos y saldos de cada venta, con su comprobante (R-11).
CREATE TABLE pago (
  id_pago                  INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del pago.',
  id_venta                 INT UNSIGNED NOT NULL
    COMMENT 'Venta a la que corresponde.',
  fecha_hora               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora del pago.',
  tipo                     ENUM('TOTAL', 'ADELANTO', 'SALDO') NOT NULL
    COMMENT 'Indica si es pago total, adelanto o saldo.',
  monto                    DECIMAL(12,2) NOT NULL
    COMMENT 'Importe pagado con IGV; es el importe total del comprobante.',
  tasa_igv                 DECIMAL(5,2) NOT NULL DEFAULT 18.00
    COMMENT 'Tasa del IGV aplicada, en porcentaje; se guarda por si la tasa legal cambia.',
  op_gravada               DECIMAL(12,2) GENERATED ALWAYS AS (ROUND(monto / (1 + tasa_igv / 100), 2)) STORED NOT NULL
    COMMENT 'Valor sin IGV (operación gravada).',
  igv                      DECIMAL(12,2) GENERATED ALWAYS AS (monto - op_gravada) STORED NOT NULL
    COMMENT 'Importe del IGV incluido en el precio.',
  medio_pago               ENUM('EFECTIVO', 'TARJETA', 'TRANSFERENCIA', 'BILLETERA_DIGITAL') NOT NULL
    COMMENT 'Medio de pago utilizado (R-11).',
  tipo_comprobante         ENUM('BOLETA', 'FACTURA') NOT NULL
    COMMENT 'Comprobante emitido (R-11).',
  numero_comprobante       VARCHAR(20) NOT NULL
    COMMENT 'Serie y número del comprobante (p. ej., B001-000123).',
  CONSTRAINT pk_pago PRIMARY KEY (id_pago),
  CONSTRAINT uq_pago_comprobante UNIQUE (numero_comprobante),
  CONSTRAINT fk_pago_id_venta FOREIGN KEY (id_venta)
    REFERENCES venta (id_venta) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_pago_monto CHECK (monto > 0),
  CONSTRAINT chk_pago_tasa_igv CHECK (tasa_igv BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Pagos totales, adelantos y saldos de cada venta, con su comprobante (R-11).';
CREATE INDEX idx_pago_fecha ON pago (fecha_hora);

-- Consultas y reclamos posteriores a la venta (RF-16).
CREATE TABLE atencion_posventa (
  id_atencion              INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la atención.',
  id_venta                 INT UNSIGNED NOT NULL
    COMMENT 'Venta a la que se refiere.',
  id_usuario               INT UNSIGNED NOT NULL
    COMMENT 'Usuario que registró la atención.',
  fecha_hora               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora del registro.',
  tipo                     ENUM('CONSULTA', 'RECLAMO') NOT NULL
    COMMENT 'Consulta o reclamo.',
  motivo                   VARCHAR(200) NOT NULL
    COMMENT 'Motivo expuesto por el cliente.',
  respuesta                VARCHAR(300) NULL
    COMMENT 'Respuesta o solución brindada.',
  estado                   ENUM('ABIERTA', 'ATENDIDA') NOT NULL DEFAULT 'ABIERTA'
    COMMENT 'Situación de la atención.',
  CONSTRAINT pk_atencion_posventa PRIMARY KEY (id_atencion),
  CONSTRAINT fk_atencion_posventa_id_venta FOREIGN KEY (id_venta)
    REFERENCES venta (id_venta) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_atencion_posventa_id_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_atencion_respuesta CHECK (estado = 'ABIERTA' OR respuesta IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Consultas y reclamos posteriores a la venta (RF-16).';

-- Pedidos personalizados o de productos en stock originados en una venta (RF-13).
CREATE TABLE pedido (
  id_pedido                INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del pedido.',
  numero                   VARCHAR(15) NOT NULL
    COMMENT 'Número correlativo del pedido.',
  id_venta                 INT UNSIGNED NOT NULL
    COMMENT 'Venta que origina el pedido; de ella se obtiene el cliente.',
  id_usuario_anula         INT UNSIGNED NULL
    COMMENT 'Gerente general que autorizó la anulación (R-07).',
  tipo                     ENUM('PERSONALIZADO', 'STOCK') NOT NULL
    COMMENT 'Personalizado (pasa por fabricación) o de stock.',
  fecha_registro           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora de registro.',
  fecha_comprometida       DATE NOT NULL
    COMMENT 'Fecha de entrega acordada con el cliente (P-03).',
  estado                   ENUM('REGISTRADO', 'EN_FABRICACION', 'LISTO_PARA_ENTREGA', 'ENTREGADO', 'ANULADO') NOT NULL DEFAULT 'REGISTRADO'
    COMMENT 'Estado actual según el diagrama de la Figura 13.',
  direccion_entrega        VARCHAR(150) NULL
    COMMENT 'Dirección de entrega, si difiere de la del cliente.',
  motivo_anulacion         VARCHAR(200) NULL
    COMMENT 'Motivo de la anulación.',
  CONSTRAINT pk_pedido PRIMARY KEY (id_pedido),
  CONSTRAINT uq_pedido_numero UNIQUE (numero),
  CONSTRAINT uq_pedido_venta UNIQUE (id_venta),
  CONSTRAINT fk_pedido_id_venta FOREIGN KEY (id_venta)
    REFERENCES venta (id_venta) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_pedido_id_usuario_anula FOREIGN KEY (id_usuario_anula)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_pedido_fecha CHECK (fecha_comprometida >= CAST(fecha_registro AS DATE)),
  CONSTRAINT chk_pedido_anulacion CHECK (estado <> 'ANULADO' OR (id_usuario_anula IS NOT NULL AND motivo_anulacion IS NOT NULL)),
  CONSTRAINT chk_pedido_tipo_estado CHECK (tipo = 'PERSONALIZADO' OR estado <> 'EN_FABRICACION')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Pedidos personalizados o de productos en stock originados en una venta (RF-13).';
CREATE INDEX idx_pedido_estado_fecha ON pedido (estado, fecha_comprometida);

-- Muebles solicitados en el pedido, con medidas, tela y acabados (P-03).
CREATE TABLE detalle_pedido (
  id_detalle_pedido        INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del ítem del pedido.',
  id_pedido                INT UNSIGNED NOT NULL
    COMMENT 'Pedido al que pertenece.',
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Mueble solicitado.',
  id_producto_tela         INT UNSIGNED NULL
    COMMENT 'Tela elegida por el cliente, registrada como producto.',
  cantidad                 INT UNSIGNED NOT NULL
    COMMENT 'Número de unidades solicitadas.',
  medidas                  VARCHAR(100) NULL
    COMMENT 'Medidas solicitadas, si es personalizado.',
  acabados                 VARCHAR(100) NULL
    COMMENT 'Acabados solicitados (color, patas, costuras).',
  observaciones            VARCHAR(200) NULL
    COMMENT 'Indicaciones adicionales del cliente.',
  CONSTRAINT pk_detalle_pedido PRIMARY KEY (id_detalle_pedido),
  CONSTRAINT uq_detalle_pedido_producto UNIQUE (id_detalle_pedido, id_producto),
  CONSTRAINT fk_detalle_pedido_id_pedido FOREIGN KEY (id_pedido)
    REFERENCES pedido (id_pedido) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_detalle_pedido_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_detalle_pedido_id_producto_tela FOREIGN KEY (id_producto_tela)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_dp_cantidad CHECK (cantidad > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Muebles solicitados en el pedido, con medidas, tela y acabados (P-03).';

-- Registro inalterable de cada cambio de estado del pedido (RF-15).
CREATE TABLE historial_estado_pedido (
  id_historial             INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del cambio de estado.',
  id_pedido                INT UNSIGNED NOT NULL
    COMMENT 'Pedido que cambió de estado.',
  id_usuario               INT UNSIGNED NOT NULL
    COMMENT 'Usuario que realizó el cambio.',
  fecha_hora               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora del cambio.',
  estado_anterior          ENUM('REGISTRADO', 'EN_FABRICACION', 'LISTO_PARA_ENTREGA', 'ENTREGADO', 'ANULADO') NULL
    COMMENT 'Estado previo; nulo en el registro inicial.',
  estado_nuevo             ENUM('REGISTRADO', 'EN_FABRICACION', 'LISTO_PARA_ENTREGA', 'ENTREGADO', 'ANULADO') NOT NULL
    COMMENT 'Estado al que pasa el pedido.',
  observacion              VARCHAR(200) NULL
    COMMENT 'Comentario sobre el cambio.',
  CONSTRAINT pk_historial_estado_pedido PRIMARY KEY (id_historial),
  CONSTRAINT fk_historial_estado_pedido_id_pedido FOREIGN KEY (id_pedido)
    REFERENCES pedido (id_pedido) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_historial_estado_pedido_id_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_hep_estados CHECK (estado_anterior IS NULL OR estado_anterior <> estado_nuevo)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Registro inalterable de cada cambio de estado del pedido (RF-15).';
CREATE INDEX idx_hep_pedido_fecha ON historial_estado_pedido (id_pedido, fecha_hora);

-- Órdenes de fabricación dirigidas al taller, por pedido o para reponer stock (RF-26).
CREATE TABLE orden_produccion (
  id_orden_produccion      INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la orden de producción.',
  numero                   VARCHAR(15) NOT NULL
    COMMENT 'Número correlativo de la orden.',
  id_detalle_pedido        INT UNSIGNED NULL
    COMMENT 'Ítem del pedido personalizado que la origina; nulo si es para reponer stock.',
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Mueble que se fabricará; si hay ítem de pedido, debe ser el mismo mueble del ítem.',
  id_tienda_destino        INT UNSIGNED NOT NULL
    COMMENT 'Tienda a la que ingresará el producto terminado.',
  id_usuario_responsable   INT UNSIGNED NOT NULL
    COMMENT 'Maestro tapicero responsable.',
  cantidad                 INT UNSIGNED NOT NULL
    COMMENT 'Unidades por fabricar.',
  especificaciones         VARCHAR(300) NULL
    COMMENT 'Medidas, tela y acabados de una orden de reposición; nula en una orden de pedido, que los toma de detalle_pedido.',
  fecha_emision            DATE NOT NULL
    COMMENT 'Fecha de emisión de la orden.',
  fecha_comprometida       DATE NOT NULL
    COMMENT 'Fecha en que el taller debe terminarla.',
  fecha_inicio             DATE NULL
    COMMENT 'Fecha real de inicio.',
  fecha_fin                DATE NULL
    COMMENT 'Fecha real de término.',
  estado                   ENUM('PENDIENTE', 'EN_PROCESO', 'TERMINADA', 'ANULADA') NOT NULL DEFAULT 'PENDIENTE'
    COMMENT 'Situación de la orden.',
  resultado_calidad        ENUM('PENDIENTE', 'APROBADO', 'OBSERVADO') NOT NULL DEFAULT 'PENDIENTE'
    COMMENT 'Resultado del control de calidad (P-07).',
  observacion_calidad      VARCHAR(200) NULL
    COMMENT 'Observaciones del control de calidad.',
  CONSTRAINT pk_orden_produccion PRIMARY KEY (id_orden_produccion),
  CONSTRAINT uq_orden_produccion_numero UNIQUE (numero),
  CONSTRAINT fk_orden_produccion_detalle_pedido FOREIGN KEY (id_detalle_pedido, id_producto)
    REFERENCES detalle_pedido (id_detalle_pedido, id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_orden_produccion_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_orden_produccion_id_tienda_destino FOREIGN KEY (id_tienda_destino)
    REFERENCES tienda (id_tienda) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_orden_produccion_id_usuario_responsable FOREIGN KEY (id_usuario_responsable)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_op_cantidad CHECK (cantidad > 0),
  CONSTRAINT chk_op_fechas CHECK (fecha_comprometida >= fecha_emision AND (fecha_fin IS NULL OR fecha_inicio IS NULL OR fecha_fin >= fecha_inicio)),
  CONSTRAINT chk_op_calidad CHECK (resultado_calidad = 'PENDIENTE' OR estado = 'TERMINADA'),
  CONSTRAINT chk_op_observacion CHECK (resultado_calidad <> 'OBSERVADO' OR observacion_calidad IS NOT NULL),
  CONSTRAINT chk_op_especificaciones CHECK ((id_detalle_pedido IS NULL) = (especificaciones IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Órdenes de fabricación dirigidas al taller, por pedido o para reponer stock (RF-26).';
CREATE INDEX idx_op_estado_fecha ON orden_produccion (estado, fecha_comprometida);

-- Insumos reservados, entregados, consumidos y devueltos por cada orden (R-08).
CREATE TABLE insumo_orden_produccion (
  id_insumo_orden          INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del insumo de la orden.',
  id_orden_produccion      INT UNSIGNED NOT NULL
    COMMENT 'Orden de producción.',
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Insumo o tela requerido.',
  cantidad_reservada       DECIMAL(10,2) NOT NULL DEFAULT 0
    COMMENT 'Cantidad reservada en el stock al emitir la orden.',
  cantidad_entregada       DECIMAL(10,2) NOT NULL DEFAULT 0
    COMMENT 'Cantidad entregada al taller (SALIDA_TALLER).',
  cantidad_consumida       DECIMAL(10,2) NOT NULL DEFAULT 0
    COMMENT 'Cantidad efectivamente utilizada.',
  cantidad_devuelta        DECIMAL(10,2) NOT NULL DEFAULT 0
    COMMENT 'Sobrante devuelto al almacén (REINGRESO_SOBRANTE).',
  CONSTRAINT pk_insumo_orden_produccion PRIMARY KEY (id_insumo_orden),
  CONSTRAINT uq_iop_orden_producto UNIQUE (id_orden_produccion, id_producto),
  CONSTRAINT fk_insumo_orden_produccion_id_orden_produccion FOREIGN KEY (id_orden_produccion)
    REFERENCES orden_produccion (id_orden_produccion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_insumo_orden_produccion_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_iop_cantidades CHECK (cantidad_reservada >= 0 AND cantidad_entregada >= 0 AND cantidad_consumida >= 0 AND cantidad_devuelta >= 0),
  CONSTRAINT chk_iop_balance CHECK (cantidad_consumida + cantidad_devuelta <= cantidad_entregada)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Insumos reservados, entregados, consumidos y devueltos por cada orden (R-08).';

-- Programación, ejecución y conformidad de las entregas de cada pedido (RF-33 a RF-36).
CREATE TABLE entrega (
  id_entrega               INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador de la entrega.',
  id_pedido                INT UNSIGNED NOT NULL
    COMMENT 'Pedido que se entrega; admite varias entregas si se reprograma.',
  id_usuario_responsable   INT UNSIGNED NOT NULL
    COMMENT 'Ayudante de entregas responsable.',
  fecha_programada         DATE NOT NULL
    COMMENT 'Fecha programada.',
  hora_programada          TIME NOT NULL
    COMMENT 'Hora programada.',
  direccion                VARCHAR(150) NOT NULL
    COMMENT 'Dirección de entrega.',
  numero_guia_remision     VARCHAR(20) NULL
    COMMENT 'Guía de remisión que acompaña la entrega.',
  estado                   ENUM('PROGRAMADA', 'ENTREGADA', 'NO_CONCRETADA') NOT NULL DEFAULT 'PROGRAMADA'
    COMMENT 'Situación de la entrega.',
  fecha_hora_entrega       DATETIME NULL
    COMMENT 'Fecha y hora reales de la entrega.',
  conformidad_cliente      TINYINT(1) NOT NULL DEFAULT 0
    COMMENT 'Indica si el cliente firmó la conformidad (P-08).',
  nombre_receptor          VARCHAR(100) NULL
    COMMENT 'Persona que recibió el pedido.',
  motivo_incidencia        VARCHAR(200) NULL
    COMMENT 'Motivo por el que no se concretó.',
  CONSTRAINT pk_entrega PRIMARY KEY (id_entrega),
  CONSTRAINT fk_entrega_id_pedido FOREIGN KEY (id_pedido)
    REFERENCES pedido (id_pedido) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_entrega_id_usuario_responsable FOREIGN KEY (id_usuario_responsable)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_entrega_concretada CHECK (estado <> 'ENTREGADA' OR (fecha_hora_entrega IS NOT NULL AND conformidad_cliente = 1 AND nombre_receptor IS NOT NULL)),
  CONSTRAINT chk_entrega_incidencia CHECK (estado <> 'NO_CONCRETADA' OR motivo_incidencia IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Programación, ejecución y conformidad de las entregas de cada pedido (RF-33 a RF-36).';
CREATE INDEX idx_entrega_programacion ON entrega (fecha_programada, estado);

-- Registro inalterable de cada ingreso, salida, traslado o ajuste de stock (R-06).
CREATE TABLE movimiento_inventario (
  id_movimiento            INT UNSIGNED NOT NULL AUTO_INCREMENT
    COMMENT 'Identificador del movimiento.',
  id_producto              INT UNSIGNED NOT NULL
    COMMENT 'Producto afectado.',
  id_tienda                INT UNSIGNED NOT NULL
    COMMENT 'Tienda en la que se afecta el stock.',
  id_usuario               INT UNSIGNED NOT NULL
    COMMENT 'Usuario que registró el movimiento.',
  id_usuario_aprueba       INT UNSIGNED NULL
    COMMENT 'Gerente general que aprobó el ajuste (P-06).',
  id_traslado              INT UNSIGNED NULL
    COMMENT 'Traslado que lo origina, si corresponde.',
  id_detalle_recepcion     INT UNSIGNED NULL
    COMMENT 'Ítem de recepción que lo origina (INGRESO_COMPRA).',
  id_detalle_venta         INT UNSIGNED NULL
    COMMENT 'Ítem de venta que lo origina (SALIDA_VENTA o REINGRESO_ANULACION).',
  id_insumo_orden          INT UNSIGNED NULL
    COMMENT 'Insumo de orden que lo origina (SALIDA_TALLER o REINGRESO_SOBRANTE).',
  id_orden_produccion      INT UNSIGNED NULL
    COMMENT 'Orden terminada que lo origina (INGRESO_PRODUCCION).',
  fecha_hora               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    COMMENT 'Fecha y hora del movimiento.',
  tipo                     ENUM('INGRESO_COMPRA', 'INGRESO_PRODUCCION', 'REINGRESO_SOBRANTE', 'REINGRESO_ANULACION', 'SALIDA_VENTA', 'SALIDA_TALLER', 'TRASLADO_SALIDA', 'TRASLADO_INGRESO', 'AJUSTE_POSITIVO', 'AJUSTE_NEGATIVO') NOT NULL
    COMMENT 'Tipo de movimiento.',
  cantidad                 DECIMAL(10,2) NOT NULL
    COMMENT 'Cantidad movida, siempre positiva; el tipo define el sentido.',
  saldo_resultante         DECIMAL(10,2) NOT NULL
    COMMENT 'Existencia en la tienda después del movimiento (R-05).',
  documento_referencia     VARCHAR(30) NOT NULL
    COMMENT 'Número del documento que sustenta el movimiento (R-06).',
  motivo                   VARCHAR(200) NULL
    COMMENT 'Justificación; obligatoria en los ajustes (P-06).',
  CONSTRAINT pk_movimiento_inventario PRIMARY KEY (id_movimiento),
  CONSTRAINT fk_movimiento_inventario_id_producto FOREIGN KEY (id_producto)
    REFERENCES producto (id_producto) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_movimiento_inventario_id_tienda FOREIGN KEY (id_tienda)
    REFERENCES tienda (id_tienda) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_movimiento_inventario_id_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_movimiento_inventario_id_usuario_aprueba FOREIGN KEY (id_usuario_aprueba)
    REFERENCES usuario (id_usuario) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_movimiento_inventario_id_traslado FOREIGN KEY (id_traslado)
    REFERENCES traslado (id_traslado) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_movimiento_inventario_id_detalle_recepcion FOREIGN KEY (id_detalle_recepcion)
    REFERENCES detalle_recepcion (id_detalle_recepcion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_movimiento_inventario_id_detalle_venta FOREIGN KEY (id_detalle_venta)
    REFERENCES detalle_venta (id_detalle_venta) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_movimiento_inventario_id_insumo_orden FOREIGN KEY (id_insumo_orden)
    REFERENCES insumo_orden_produccion (id_insumo_orden) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_movimiento_inventario_id_orden_produccion FOREIGN KEY (id_orden_produccion)
    REFERENCES orden_produccion (id_orden_produccion) ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT chk_mov_cantidad CHECK (cantidad > 0),
  CONSTRAINT chk_mov_saldo CHECK (saldo_resultante >= 0),
  CONSTRAINT chk_mov_anulacion CHECK (tipo <> 'REINGRESO_ANULACION' OR id_detalle_venta IS NOT NULL),
  CONSTRAINT chk_mov_origen CHECK (
        (tipo <> 'INGRESO_COMPRA' OR id_detalle_recepcion IS NOT NULL)
    AND (tipo <> 'INGRESO_PRODUCCION' OR id_orden_produccion IS NOT NULL)
    AND (tipo NOT IN ('SALIDA_TALLER','REINGRESO_SOBRANTE') OR id_insumo_orden IS NOT NULL)
    AND (tipo <> 'SALIDA_VENTA' OR id_detalle_venta IS NOT NULL)
    AND (tipo NOT IN ('TRASLADO_SALIDA','TRASLADO_INGRESO') OR id_traslado IS NOT NULL)),
  CONSTRAINT chk_mov_ajuste CHECK (tipo NOT IN ('AJUSTE_POSITIVO','AJUSTE_NEGATIVO') OR (motivo IS NOT NULL AND id_usuario_aprueba IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Registro inalterable de cada ingreso, salida, traslado o ajuste de stock (R-06).';
CREATE INDEX idx_mov_kardex ON movimiento_inventario (id_producto, id_tienda, fecha_hora);
CREATE INDEX idx_mov_tipo_fecha ON movimiento_inventario (tipo, fecha_hora);

-- ---------------------------------------------------------------------
-- DISPARADORES DE INMUTABILIDAD (R-06, CA-11 y CA-14) - parte obligatoria
-- Se crean antes de los datos iniciales: si fallan (por ejemplo, porque falta
-- log_bin_trust_function_creators = 1), el script se detiene y la instalación
-- no queda en uso sin ellos.
-- ---------------------------------------------------------------------
DELIMITER //
CREATE TRIGGER trg_movimiento_inventario_bu BEFORE UPDATE ON movimiento_inventario
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'R-06: los movimientos de inventario no se modifican; registre un ajuste.';
END//
CREATE TRIGGER trg_movimiento_inventario_bd BEFORE DELETE ON movimiento_inventario
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'R-06: los movimientos de inventario no se eliminan.';
END//
CREATE TRIGGER trg_historial_estado_pedido_bu BEFORE UPDATE ON historial_estado_pedido
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'CA-11: el historial de estados del pedido no se modifica.';
END//
CREATE TRIGGER trg_historial_estado_pedido_bd BEFORE DELETE ON historial_estado_pedido
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'CA-11: el historial de estados del pedido no se elimina.';
END//
DELIMITER ;

-- ---------------------------------------------------------------------
-- DATOS INICIALES (necesarios para que el sistema pueda usarse)
-- ---------------------------------------------------------------------
INSERT INTO tienda (nombre, ciudad, direccion) VALUES
  ('Tienda Lima', 'Lima', 'Por definir'),
  ('Tienda Ayacucho', 'Ayacucho', 'Por definir');

INSERT INTO rol (nombre, descripcion) VALUES
  ('Gerente general', 'Aprueba precios, órdenes de compra, ajustes y anulaciones; administra usuarios.'),
  ('Vendedor', 'Registra clientes, cotizaciones, ventas, pagos y pedidos.'),
  ('Encargado de telas', 'Gestiona el inventario de materiales de tapicería, las compras y las recepciones.'),
  ('Contadora', 'Consulta ventas, pagos, compras y reportes.'),
  ('Maestro tapicero', 'Gestiona las órdenes de producción, el consumo de insumos y el control de calidad.'),
  ('Ayudante de entregas y carga', 'Registra la ejecución y conformidad de las entregas y la recepción de traslados.');

-- Catálogo de permisos por módulo (RF-48)
INSERT INTO permiso (modulo, accion) VALUES
  ('CATALOGO', 'CONSULTAR'),
  ('CATALOGO', 'REGISTRAR_PRODUCTO'),
  ('CATALOGO', 'GESTIONAR_PRECIOS'),
  ('CATALOGO', 'REGISTRAR_METAS'),
  ('VENTAS', 'CONSULTAR'),
  ('VENTAS', 'REGISTRAR_COTIZACION'),
  ('VENTAS', 'REGISTRAR_VENTA'),
  ('VENTAS', 'ANULAR_VENTA'),
  ('VENTAS', 'REGISTRAR_POSVENTA'),
  ('PEDIDOS', 'CONSULTAR'),
  ('PEDIDOS', 'REGISTRAR_PEDIDO'),
  ('PEDIDOS', 'ANULAR_PEDIDO'),
  ('PEDIDOS', 'GESTIONAR_PRODUCCION'),
  ('PEDIDOS', 'CONTROL_CALIDAD'),
  ('INVENTARIO', 'CONSULTAR'),
  ('INVENTARIO', 'REGISTRAR_MOVIMIENTO'),
  ('INVENTARIO', 'REGISTRAR_TRASLADO'),
  ('INVENTARIO', 'RECIBIR_TRASLADO'),
  ('INVENTARIO', 'APROBAR_AJUSTE'),
  ('COMPRAS', 'CONSULTAR'),
  ('COMPRAS', 'GESTIONAR_PROVEEDORES'),
  ('COMPRAS', 'REGISTRAR_ORDEN'),
  ('COMPRAS', 'APROBAR_ORDEN'),
  ('COMPRAS', 'REGISTRAR_RECEPCION'),
  ('ENTREGAS', 'CONSULTAR'),
  ('ENTREGAS', 'PROGRAMAR'),
  ('ENTREGAS', 'REGISTRAR_ENTREGA'),
  ('CLIENTES', 'CONSULTAR'),
  ('CLIENTES', 'REGISTRAR'),
  ('CLIENTES', 'REGISTRAR_SEGUIMIENTO'),
  ('REPORTES', 'CONSULTAR_VENTAS'),
  ('REPORTES', 'CONSULTAR_INVENTARIO'),
  ('REPORTES', 'CONSULTAR_COMPRAS'),
  ('REPORTES', 'CONSULTAR_CLIENTES'),
  ('SEGURIDAD', 'GESTIONAR_USUARIOS'),
  ('SEGURIDAD', 'GESTIONAR_ROLES'),
  ('SEGURIDAD', 'CONSULTAR_BITACORA');

-- Asignación de permisos a cada rol (R-02)
INSERT INTO rol_permiso (id_rol, id_permiso)
SELECT r.id_rol, p.id_permiso FROM rol r JOIN permiso p
 WHERE r.nombre = 'Gerente general' AND (p.modulo, p.accion) IN (
   ('CATALOGO','CONSULTAR'),
   ('CATALOGO','REGISTRAR_PRODUCTO'),
   ('CATALOGO','GESTIONAR_PRECIOS'),
   ('CATALOGO','REGISTRAR_METAS'),
   ('VENTAS','CONSULTAR'),
   ('VENTAS','REGISTRAR_COTIZACION'),
   ('VENTAS','REGISTRAR_VENTA'),
   ('VENTAS','ANULAR_VENTA'),
   ('VENTAS','REGISTRAR_POSVENTA'),
   ('PEDIDOS','CONSULTAR'),
   ('PEDIDOS','REGISTRAR_PEDIDO'),
   ('PEDIDOS','ANULAR_PEDIDO'),
   ('PEDIDOS','GESTIONAR_PRODUCCION'),
   ('PEDIDOS','CONTROL_CALIDAD'),
   ('INVENTARIO','CONSULTAR'),
   ('INVENTARIO','REGISTRAR_MOVIMIENTO'),
   ('INVENTARIO','REGISTRAR_TRASLADO'),
   ('INVENTARIO','RECIBIR_TRASLADO'),
   ('INVENTARIO','APROBAR_AJUSTE'),
   ('COMPRAS','CONSULTAR'),
   ('COMPRAS','GESTIONAR_PROVEEDORES'),
   ('COMPRAS','REGISTRAR_ORDEN'),
   ('COMPRAS','APROBAR_ORDEN'),
   ('COMPRAS','REGISTRAR_RECEPCION'),
   ('ENTREGAS','CONSULTAR'),
   ('ENTREGAS','PROGRAMAR'),
   ('ENTREGAS','REGISTRAR_ENTREGA'),
   ('CLIENTES','CONSULTAR'),
   ('CLIENTES','REGISTRAR'),
   ('CLIENTES','REGISTRAR_SEGUIMIENTO'),
   ('REPORTES','CONSULTAR_VENTAS'),
   ('REPORTES','CONSULTAR_INVENTARIO'),
   ('REPORTES','CONSULTAR_COMPRAS'),
   ('REPORTES','CONSULTAR_CLIENTES'),
   ('SEGURIDAD','GESTIONAR_USUARIOS'),
   ('SEGURIDAD','GESTIONAR_ROLES'),
   ('SEGURIDAD','CONSULTAR_BITACORA'));
INSERT INTO rol_permiso (id_rol, id_permiso)
SELECT r.id_rol, p.id_permiso FROM rol r JOIN permiso p
 WHERE r.nombre = 'Vendedor' AND (p.modulo, p.accion) IN (
   ('CATALOGO','CONSULTAR'),
   ('VENTAS','CONSULTAR'),
   ('VENTAS','REGISTRAR_COTIZACION'),
   ('VENTAS','REGISTRAR_VENTA'),
   ('VENTAS','REGISTRAR_POSVENTA'),
   ('PEDIDOS','CONSULTAR'),
   ('PEDIDOS','REGISTRAR_PEDIDO'),
   ('INVENTARIO','CONSULTAR'),
   ('ENTREGAS','CONSULTAR'),
   ('ENTREGAS','PROGRAMAR'),
   ('CLIENTES','CONSULTAR'),
   ('CLIENTES','REGISTRAR'),
   ('CLIENTES','REGISTRAR_SEGUIMIENTO'));
INSERT INTO rol_permiso (id_rol, id_permiso)
SELECT r.id_rol, p.id_permiso FROM rol r JOIN permiso p
 WHERE r.nombre = 'Encargado de telas' AND (p.modulo, p.accion) IN (
   ('CATALOGO','CONSULTAR'),
   ('CATALOGO','REGISTRAR_PRODUCTO'),
   ('PEDIDOS','CONSULTAR'),
   ('INVENTARIO','CONSULTAR'),
   ('INVENTARIO','REGISTRAR_MOVIMIENTO'),
   ('INVENTARIO','REGISTRAR_TRASLADO'),
   ('INVENTARIO','RECIBIR_TRASLADO'),
   ('COMPRAS','CONSULTAR'),
   ('COMPRAS','GESTIONAR_PROVEEDORES'),
   ('COMPRAS','REGISTRAR_ORDEN'),
   ('COMPRAS','REGISTRAR_RECEPCION'),
   ('REPORTES','CONSULTAR_INVENTARIO'),
   ('REPORTES','CONSULTAR_COMPRAS'));
INSERT INTO rol_permiso (id_rol, id_permiso)
SELECT r.id_rol, p.id_permiso FROM rol r JOIN permiso p
 WHERE r.nombre = 'Contadora' AND (p.modulo, p.accion) IN (
   ('CATALOGO','CONSULTAR'),
   ('VENTAS','CONSULTAR'),
   ('PEDIDOS','CONSULTAR'),
   ('INVENTARIO','CONSULTAR'),
   ('COMPRAS','CONSULTAR'),
   ('CLIENTES','CONSULTAR'),
   ('REPORTES','CONSULTAR_VENTAS'),
   ('REPORTES','CONSULTAR_INVENTARIO'),
   ('REPORTES','CONSULTAR_COMPRAS'),
   ('REPORTES','CONSULTAR_CLIENTES'));
INSERT INTO rol_permiso (id_rol, id_permiso)
SELECT r.id_rol, p.id_permiso FROM rol r JOIN permiso p
 WHERE r.nombre = 'Maestro tapicero' AND (p.modulo, p.accion) IN (
   ('CATALOGO','CONSULTAR'),
   ('PEDIDOS','CONSULTAR'),
   ('PEDIDOS','GESTIONAR_PRODUCCION'),
   ('PEDIDOS','CONTROL_CALIDAD'),
   ('INVENTARIO','CONSULTAR'));
INSERT INTO rol_permiso (id_rol, id_permiso)
SELECT r.id_rol, p.id_permiso FROM rol r JOIN permiso p
 WHERE r.nombre = 'Ayudante de entregas y carga' AND (p.modulo, p.accion) IN (
   ('PEDIDOS','CONSULTAR'),
   ('INVENTARIO','CONSULTAR'),
   ('INVENTARIO','RECIBIR_TRASLADO'),
   ('ENTREGAS','CONSULTAR'),
   ('ENTREGAS','REGISTRAR_ENTREGA'));

-- Usuario inicial: gerente general (P-10)
-- El hash llega en @hash_gerente (ver el encabezado). Si la variable no se
-- definió, contrasena_hash queda nula y la sentencia falla (columna NOT NULL).
-- La contraseña temporal se entrega al gerente por un medio aparte y el sistema
-- exige cambiarla en el primer acceso (debe_cambiar_contrasena = 1).
INSERT INTO usuario (id_rol, id_tienda, nombre_completo, nombre_usuario, contrasena_hash,
                     estado, intentos_fallidos, debe_cambiar_contrasena)
SELECT id_rol, NULL, 'Gerente general', 'gerente', @hash_gerente, 'ACTIVO', 0, 1
  FROM rol WHERE nombre = 'Gerente general';

-- ---------------------------------------------------------------------
-- VERIFICACIÓN FINAL: la instalación debe tener los cuatro disparadores y
-- la cuenta del gerente; de lo contrario, la sentencia falla.
-- ---------------------------------------------------------------------
CREATE TEMPORARY TABLE verificacion_instalacion (
  disparadores INT NOT NULL,
  gerentes     INT NOT NULL,
  CONSTRAINT chk_verificacion_disparadores CHECK (disparadores = 4),
  CONSTRAINT chk_verificacion_gerente CHECK (gerentes = 1)
);
INSERT INTO verificacion_instalacion
SELECT (SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = 'dlucia_sistema'),
       (SELECT COUNT(*) FROM usuario WHERE nombre_usuario = 'gerente');
DROP TEMPORARY TABLE verificacion_instalacion;

-- ---------------------------------------------------------------------
-- USUARIOS DE MYSQL (en el servidor virtual se crean desde la consola de MySQL
-- con el usuario administrador)
-- ---------------------------------------------------------------------
-- CREATE USER 'dlucia_app'@'localhost' IDENTIFIED BY '********';
-- GRANT SELECT, INSERT, UPDATE, DELETE ON dlucia_sistema.* TO 'dlucia_app'@'localhost';
-- CREATE USER 'dlucia_deploy'@'localhost' IDENTIFIED BY '********';
-- GRANT ALL PRIVILEGES ON dlucia_sistema.* TO 'dlucia_deploy'@'localhost';
-- CREATE USER 'dlucia_backup'@'localhost' IDENTIFIED BY '********';
-- GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER ON dlucia_sistema.* TO 'dlucia_backup'@'localhost';
-- Nota: TRIGGER es necesario para que mysqldump copie los disparadores, pero
-- también permitiría eliminarlos; por eso las credenciales de dlucia_backup
-- se guardan en un archivo de opciones legible solo por root (chmod 600).
-- La copia nocturna se genera con:
--   mysqldump -u dlucia_backup --single-transaction --no-tablespaces --triggers dlucia_sistema
-- Desde MySQL 8.0.21, mysqldump exige el privilegio global PROCESS si no se
-- indica --no-tablespaces; con esa opción, dlucia_backup no necesita más privilegios.

-- ---------------------------------------------------------------------
-- CONSULTA QUE GENERA EL DICCIONARIO DE DATOS (apartado 7.3.3)
-- ---------------------------------------------------------------------
-- SELECT c.TABLE_NAME AS tabla, c.COLUMN_NAME AS columna, c.COLUMN_TYPE AS tipo,
--        c.IS_NULLABLE AS nulo,
--        (SELECT GROUP_CONCAT(DISTINCT CASE tc.CONSTRAINT_TYPE WHEN 'PRIMARY KEY' THEN 'PK'
--                WHEN 'FOREIGN KEY' THEN 'FK' ELSE 'UK' END ORDER BY 1 SEPARATOR ', ')
--           FROM information_schema.KEY_COLUMN_USAGE k
--           JOIN information_schema.TABLE_CONSTRAINTS tc
--             ON tc.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND tc.TABLE_NAME = k.TABLE_NAME
--            AND tc.CONSTRAINT_NAME = k.CONSTRAINT_NAME
--          WHERE k.TABLE_SCHEMA = c.TABLE_SCHEMA AND k.TABLE_NAME = c.TABLE_NAME
--            AND k.COLUMN_NAME = c.COLUMN_NAME) AS clave,
--        c.COLUMN_DEFAULT AS valor_por_defecto, c.EXTRA AS extra,
--        c.COLUMN_COMMENT AS descripcion
--   FROM information_schema.COLUMNS c
--  WHERE c.TABLE_SCHEMA = 'dlucia_sistema'
--  ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;
