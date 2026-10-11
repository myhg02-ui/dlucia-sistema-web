const express = require('express');
const cors = require('cors');
const mysql = require('mysql2/promise');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname)));

// Conexión a la base de datos MySQL local (dlucia_sistema)
const pool = mysql.createPool({
  host: process.env.DB_HOST || 'localhost',
  user: process.env.DB_USER || 'root',
  password: process.env.DB_PASSWORD || 'root',
  database: process.env.DB_NAME || 'dlucia_sistema',
  port: process.env.DB_PORT || 3306,
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0
});

// ==========================================
// 1. AUTENTICACIÓN / LOGIN (R-01 y RF-45)
// ==========================================
app.post('/api/login', async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).json({ ok: false, error: 'Usuario y contraseña requeridos' });
  }

  try {
    const [users] = await pool.query(
      `SELECT u.id_usuario, u.nombre_completo, u.nombre_usuario, u.estado, r.nombre AS rol
       FROM usuario u
       JOIN rol r ON u.id_rol = r.id_rol
       WHERE u.nombre_usuario = ? AND u.estado = 'ACTIVO' LIMIT 1`,
      [username.trim()]
    );

    if (users.length === 0) {
      return res.status(401).json({ ok: false, error: 'Usuario no encontrado o inactivo.' });
    }

    const u = users[0];
    // Para entornos locales y demo de curso universitario
    const valid = (password === 'dlucia2026' || password === 'root' || password === 'admin');
    if (!valid) {
      return res.status(401).json({ ok: false, error: 'Contraseña incorrecta.' });
    }

    res.json({
      ok: true,
      mensaje: 'Acceso autorizado',
      usuario: {
        id: u.id_usuario,
        nombre: u.nombre_completo,
        username: u.nombre_usuario,
        rol: u.rol
      }
    });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

// ==========================================
// 2. PRODUCTOS E INVENTARIO (RF-01 a RF-06)
// ==========================================
app.get('/api/productos', async (req, res) => {
  try {
    const query = `
      SELECT p.id_producto, p.codigo, p.nombre, p.categoria, p.linea_negocio, 
             p.unidad_medida, p.stock_minimo,
             IFNULL(dlp.precio_venta, 0.00) AS precio_venta,
             IFNULL(s.existencia, 0) AS stock_actual
      FROM producto p
      LEFT JOIN lista_precios lp ON lp.estado = 'VIGENTE'
      LEFT JOIN detalle_lista_precios dlp ON dlp.id_producto = p.id_producto AND dlp.id_lista_precios = lp.id_lista_precios
      LEFT JOIN stock s ON p.id_producto = s.id_producto AND s.id_tienda = 1
      WHERE p.activo = 1
      ORDER BY p.id_producto ASC
    `;
    const [productos] = await pool.query(query);
    res.json({ ok: true, data: productos });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.post('/api/productos', async (req, res) => {
  const { codigo, nombre, categoria, unidad, precio, stock_minimo, linea } = req.body;
  if (!codigo || !nombre) {
    return res.status(400).json({ ok: false, error: 'Código y nombre son obligatorios.' });
  }

  // Normalizar unidades según el ENUM estricto de dlucia_sistema.sql
  const u = String(unidad || '').toUpperCase().trim();
  let unidadValida = 'UNIDAD';
  if (u.includes('MET') || u === 'M') unidadValida = 'METRO';
  else if (u.includes('PLAN')) unidadValida = 'PLANCHA';
  else if (u.includes('KIL') || u === 'KG') unidadValida = 'KILOGRAMO';
  else if (u.includes('JUE')) unidadValida = 'JUEGO';

  // Normalizar línea de negocio
  let lineaValida = 'MUEBLES';
  const catLower = (categoria || '').toLowerCase();
  if (linea === 'MATERIALES_TAPICERIA' || catLower.includes('tela') || catLower.includes('espuma') || catLower.includes('tapicer')) {
    lineaValida = 'MATERIALES_TAPICERIA';
  }

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    // 1. Insertar producto
    const [prodRes] = await conn.query(
      `INSERT INTO producto (codigo, nombre, categoria, linea_negocio, unidad_medida, stock_minimo, activo)
       VALUES (?, ?, ?, ?, ?, ?, 1)`,
      [codigo.trim().toUpperCase(), nombre.trim(), categoria || 'General', lineaValida, unidadValida, Number(stock_minimo) || 0]
    );
    const id_producto = prodRes.insertId;

    // 2. Inicializar stock en Tienda Lima (tienda 1)
    await conn.query(
      `INSERT INTO stock (id_producto, id_tienda, existencia, ubicacion)
       VALUES (?, 1, 0, 'Almacén Lima')
       ON DUPLICATE KEY UPDATE existencia = existencia`,
      [id_producto]
    );

    // 3. Registrar precio en la lista VIGENTE
    if (precio && Number(precio) > 0) {
      await conn.query(
        `INSERT INTO detalle_lista_precios (id_lista_precios, id_producto, precio_venta)
         VALUES (1, ?, ?)
         ON DUPLICATE KEY UPDATE precio_venta = VALUES(precio_venta)`,
        [id_producto, Number(precio)]
      );
    }

    await conn.commit();
    res.json({ ok: true, mensaje: 'Producto creado en MySQL exitosamente', id_producto });
  } catch (error) {
    await conn.rollback();
    res.status(500).json({ ok: false, error: error.message });
  } finally {
    conn.release();
  }
});

// Movimiento de stock (Entrada / Salida)
app.post('/api/movimiento', async (req, res) => {
  const { codigo, tipo, cantidad } = req.body; // tipo: 'Entrada' o 'Salida'
  const cant = Number(cantidad);
  if (!codigo || !cant || cant <= 0) {
    return res.status(400).json({ ok: false, error: 'Datos de movimiento inválidos' });
  }

  try {
    const [prod] = await pool.query('SELECT id_producto, nombre FROM producto WHERE codigo = ? LIMIT 1', [codigo]);
    if (prod.length === 0) return res.status(404).json({ ok: false, error: 'Producto no encontrado' });

    const id_producto = prod[0].id_producto;
    const diff = (tipo === 'Entrada') ? cant : -cant;

    await pool.query(
      `UPDATE stock SET existencia = GREATEST(0, existencia + ?) WHERE id_producto = ? AND id_tienda = 1`,
      [diff, id_producto]
    );

    const [[stk]] = await pool.query('SELECT existencia FROM stock WHERE id_producto = ? AND id_tienda = 1', [id_producto]);

    res.json({
      ok: true,
      mensaje: `${tipo} de ${cant} registrada en MySQL`,
      nuevo_stock: stk.existencia
    });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

// ==========================================
// 3. CLIENTES (RF-38 a RF-40)
// ==========================================
app.get('/api/clientes', async (req, res) => {
  try {
    const query = `
      SELECT id_cliente, tipo_documento, numero_documento, nombres_razon_social,
             telefono, correo, direccion, clasificacion, fecha_registro
      FROM cliente
      ORDER BY id_cliente DESC
    `;
    const [clientes] = await pool.query(query);
    res.json({ ok: true, data: clientes });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.post('/api/clientes', async (req, res) => {
  const { documento, nombre, telefono, tipo, correo, direccion } = req.body;
  if (!nombre || !telefono) {
    return res.status(400).json({ ok: false, error: 'Nombre y teléfono son obligatorios.' });
  }

  // Cumplir con chk_cliente_formato_doc y chk_cliente_tipo_numero del SQL
  let tipo_doc = null;
  let num_doc = null;
  const docLimpio = String(documento || '').trim();

  if (docLimpio.length === 8 && /^\d{8}$/.test(docLimpio)) {
    tipo_doc = 'DNI';
    num_doc = docLimpio;
  } else if (docLimpio.length === 11 && /^\d{11}$/.test(docLimpio)) {
    tipo_doc = 'RUC';
    num_doc = docLimpio;
  }

  // Clasificación estricta: 'POTENCIAL' o 'CLIENTE'
  let clasificacion = 'POTENCIAL';
  const tStr = String(tipo || '').toUpperCase();
  if (tStr.includes('CLIENTE') && !tStr.includes('POTENCIAL')) {
    if (!num_doc) {
      return res.status(400).json({ ok: false, error: 'Un cliente formal requiere DNI (8 dígitos) o RUC (11 dígitos).' });
    }
    clasificacion = 'CLIENTE';
  }

  try {
    const [resInsert] = await pool.query(
      `INSERT INTO cliente (tipo_documento, numero_documento, nombres_razon_social, telefono, correo, direccion, clasificacion)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [tipo_doc, num_doc, nombre.trim(), telefono.trim(), correo || null, direccion || null, clasificacion]
    );

    res.json({ ok: true, mensaje: 'Cliente registrado en MySQL con éxito', id_cliente: resInsert.insertId });
  } catch (error) {
    if (error.code === 'ER_DUP_ENTRY') {
      return res.status(400).json({ ok: false, error: 'Ese número de documento o teléfono ya está registrado.' });
    }
    res.status(500).json({ ok: false, error: error.message });
  }
});

// ==========================================
// 4. COTIZACIONES (RF-10)
// ==========================================
app.post('/api/cotizacion', async (req, res) => {
  const { nombre, tel, mail, linea, msg } = req.body;
  if (!nombre || !tel) {
    return res.status(400).json({ ok: false, error: 'Nombre y teléfono son obligatorios.' });
  }

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    let id_cliente;
    const [existentes] = await conn.query('SELECT id_cliente FROM cliente WHERE telefono = ? LIMIT 1', [tel.trim()]);

    if (existentes.length > 0) {
      id_cliente = existentes[0].id_cliente;
    } else {
      const [nuevo] = await conn.query(
        'INSERT INTO cliente (nombres_razon_social, telefono, correo, clasificacion) VALUES (?, ?, ?, "POTENCIAL")',
        [nombre.trim(), tel.trim(), mail ? mail.trim() : null]
      );
      id_cliente = nuevo.insertId;
    }

    const correlativo = 'COT-' + Date.now().toString().slice(-6);
    const hoy = new Date().toISOString().slice(0, 10);
    const validez = new Date(Date.now() + 15 * 86400000).toISOString().slice(0, 10);

    const [cotRes] = await conn.query(
      `INSERT INTO cotizacion (numero, id_cliente, id_usuario, id_tienda, fecha, fecha_validez, estado, total)
       VALUES (?, ?, 1, 1, ?, ?, 'VIGENTE', 0.00)`,
      [correlativo, id_cliente, hoy, validez]
    );

    if (msg || linea) {
      const detalle = `Interés: ${linea || 'General'} | Mensaje: ${msg || 'Sin mensaje'}`;
      await conn.query(
        `INSERT INTO seguimiento (id_cliente, id_usuario, id_cotizacion, accion, resultado)
         VALUES (?, 1, ?, 'Solicitud Web', ?)`,
        [id_cliente, cotRes.insertId, detalle]
      );
    }

    await conn.commit();
    res.json({
      ok: true,
      mensaje: '¡Cotización registrada con éxito en MySQL!',
      numero: correlativo,
      id_cliente
    });
  } catch (error) {
    await conn.rollback();
    res.status(500).json({ ok: false, error: error.message });
  } finally {
    conn.release();
  }
});

// ==========================================
// 5. PEDIDOS (RF-13 a RF-15 - Venta -> Pedido)
// ==========================================
app.get('/api/pedidos', async (req, res) => {
  try {
    const query = `
      SELECT p.id_pedido, p.numero, cl.nombres_razon_social AS cliente,
             IFNULL(dp.observaciones, 'Pedido personalizado') AS detalle,
             p.fecha_comprometida, p.estado
      FROM pedido p
      JOIN venta v ON p.id_venta = v.id_venta
      JOIN cliente cl ON v.id_cliente = cl.id_cliente
      LEFT JOIN detalle_pedido dp ON p.id_pedido = dp.id_pedido
      ORDER BY p.id_pedido DESC
    `;
    const [pedidos] = await pool.query(query);
    res.json({ ok: true, data: pedidos });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.post('/api/pedidos', async (req, res) => {
  const { id_cliente, cliente_nombre, descripcion, fecha_entrega } = req.body;

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    // 1. Obtener cliente
    let clienteId = id_cliente;
    if (!clienteId && cliente_nombre) {
      const [cl] = await conn.query('SELECT id_cliente FROM cliente WHERE nombres_razon_social = ? LIMIT 1', [cliente_nombre]);
      if (cl.length > 0) clienteId = cl[0].id_cliente;
    }

    if (!clienteId) {
      const [todosCli] = await conn.query('SELECT id_cliente FROM cliente LIMIT 1');
      if (todosCli.length === 0) throw new Error('Debe existir al menos un cliente en la base de datos.');
      clienteId = todosCli[0].id_cliente;
    }

    // 2. En el modelo relacional, un pedido REQUIERE una venta originaria (id_venta NOT NULL)
    const numVenta = 'VTA-' + Date.now().toString().slice(-6);
    const [vtaRes] = await conn.query(
      `INSERT INTO venta (numero, id_cliente, id_usuario, id_tienda, total, tasa_igv, estado)
       VALUES (?, ?, 1, 1, 0.00, 18.00, 'CONCRETADA')`,
      [numVenta, clienteId]
    );
    const id_venta = vtaRes.insertId;

    // 3. Crear pedido formal
    const numPedido = 'PED-' + Date.now().toString().slice(-5);
    const fechaComp = fecha_entrega || new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10);

    const [pedRes] = await conn.query(
      `INSERT INTO pedido (numero, id_venta, tipo, fecha_comprometida, estado)
       VALUES (?, ?, 'PERSONALIZADO', ?, 'REGISTRADO')`,
      [numPedido, id_venta, fechaComp]
    );
    const id_pedido = pedRes.insertId;

    // 4. Detalle de pedido y primer producto
    const [prodPrimer] = await conn.query('SELECT id_producto FROM producto LIMIT 1');
    const id_prod = (prodPrimer.length > 0) ? prodPrimer[0].id_producto : 1;

    await conn.query(
      `INSERT INTO detalle_pedido (id_pedido, id_producto, cantidad, observaciones)
       VALUES (?, ?, 1, ?)`,
      [id_pedido, id_prod, descripcion || 'Mueble a medida']
    );

    // 5. Historial inmutable de estados (RF-15)
    await conn.query(
      `INSERT INTO historial_estado_pedido (id_pedido, id_usuario, estado_anterior, estado_nuevo, observacion)
       VALUES (?, 1, NULL, 'REGISTRADO', 'Registro inicial del pedido')`,
      [id_pedido]
    );

    await conn.commit();
    res.json({ ok: true, mensaje: 'Pedido registrado en MySQL', id_pedido, numero: numPedido });
  } catch (error) {
    await conn.rollback();
    res.status(500).json({ ok: false, error: error.message });
  } finally {
    conn.release();
  }
});

// Avanzar estado de pedido (REGISTRADO -> EN_FABRICACION -> LISTO_PARA_ENTREGA -> ENTREGADO)
app.post('/api/pedidos/:id/avanzar', async (req, res) => {
  const { id } = req.params;
  const ESTADOS = ['REGISTRADO', 'EN_FABRICACION', 'LISTO_PARA_ENTREGA', 'ENTREGADO'];

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    const [rows] = await conn.query('SELECT id_pedido, estado FROM pedido WHERE id_pedido = ? OR numero = ? LIMIT 1', [id, id]);
    if (rows.length === 0) return res.status(404).json({ ok: false, error: 'Pedido no encontrado' });

    const p = rows[0];
    const idxActual = ESTADOS.indexOf(p.estado);
    if (idxActual === -1 || idxActual >= ESTADOS.length - 1) {
      return res.status(400).json({ ok: false, error: 'El pedido ya está en su estado final o anulado.' });
    }

    const estadoNuevo = ESTADOS[idxActual + 1];

    await conn.query('UPDATE pedido SET estado = ? WHERE id_pedido = ?', [estadoNuevo, p.id_pedido]);

    await conn.query(
      `INSERT INTO historial_estado_pedido (id_pedido, id_usuario, estado_anterior, estado_nuevo, observacion)
       VALUES (?, 1, ?, ?, 'Avance de estado desde panel administrativo')`,
      [p.id_pedido, p.estado, estadoNuevo]
    );

    await conn.commit();
    res.json({ ok: true, mensaje: `Pedido actualizado a ${estadoNuevo}`, estado: estadoNuevo });
  } catch (error) {
    await conn.rollback();
    res.status(500).json({ ok: false, error: error.message });
  } finally {
    conn.release();
  }
});

// ==========================================
// 6. RESUMEN / KPIS PARA EL DASHBOARD
// ==========================================
app.get('/api/resumen', async (req, res) => {
  try {
    const [[prod]] = await pool.query('SELECT COUNT(*) AS total FROM producto WHERE activo = 1');
    const [[low]] = await pool.query(`
      SELECT COUNT(*) AS total 
      FROM producto p 
      JOIN stock s ON p.id_producto = s.id_producto 
      WHERE s.existencia <= p.stock_minimo AND p.activo = 1
    `);
    const [[cli]] = await pool.query('SELECT COUNT(*) AS total FROM cliente');
    const [[ped]] = await pool.query("SELECT COUNT(*) AS total FROM pedido WHERE estado != 'ENTREGADO' AND estado != 'ANULADO'");

    res.json({
      ok: true,
      kpis: {
        productos: prod.total,
        stock_bajo: low.total,
        pedidos_activos: ped.total,
        clientes: cli.total
      }
    });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

// ==========================================
// 7. PROMOCIONES (MySQL)
// ==========================================
app.get('/api/promociones', async (req, res) => {
  try {
    const [rows] = await pool.query(
      `SELECT id_promocion, titulo, descripcion, porcentaje_descuento, fecha_limite, activa
       FROM promocion ORDER BY id_promocion DESC`
    );
    res.json({ ok: true, data: rows });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.post('/api/promociones', async (req, res) => {
  const { titulo, descripcion, descuento, fecha_limite } = req.body;
  if (!titulo || !descuento) {
    return res.status(400).json({ ok: false, error: 'Título y descuento son obligatorios' });
  }
  try {
    const [ins] = await pool.query(
      `INSERT INTO promocion (titulo, descripcion, porcentaje_descuento, fecha_limite, activa)
       VALUES (?, ?, ?, ?, 1)`,
      [titulo.trim(), descripcion || '', Number(descuento), fecha_limite || null]
    );
    res.json({ ok: true, mensaje: 'Promoción guardada en MySQL', id_promocion: ins.insertId });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.post('/api/promociones/:id/toggle', async (req, res) => {
  const { id } = req.params;
  try {
    await pool.query('UPDATE promocion SET activa = IF(activa = 1, 0, 1) WHERE id_promocion = ?', [id]);
    res.json({ ok: true, mensaje: 'Estado actualizado' });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.delete('/api/promociones/:id', async (req, res) => {
  const { id } = req.params;
  try {
    await pool.query('DELETE FROM promocion WHERE id_promocion = ?', [id]);
    res.json({ ok: true, mensaje: 'Promoción eliminada de MySQL' });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

// Servir la página pública
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

// Servir el panel administrador
app.get('/admin', (req, res) => {
  res.sendFile(path.join(__dirname, 'admin.html'));
});

app.listen(PORT, () => {
  console.log(`====================================================`);
  console.log(`🚀 Servidor D'Lucia Muebles iniciado en:`);
  console.log(`👉 Web pública:        http://localhost:${PORT}`);
  console.log(`👉 Panel administrador: http://localhost:${PORT}/admin.html`);
  console.log(`👉 Conexión MySQL:     localhost:3306 (dlucia_sistema)`);
  console.log(`====================================================`);
});
