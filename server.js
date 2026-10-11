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

// Conexión a la base de datos MySQL local
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

// 1. Estado de la conexión
app.get('/api/status', async (req, res) => {
  try {
    const [rows] = await pool.query('SELECT 1 + 1 AS resultado');
    res.json({ ok: true, mensaje: 'Conectado a MySQL local con éxito', resultado: rows[0].resultado });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

// 2. Obtener productos del catálogo desde MySQL
app.get('/api/productos', async (req, res) => {
  try {
    const query = `
      SELECT p.id_producto, p.codigo, p.nombre, p.categoria, p.linea_negocio, 
             p.unidad_medida, p.stock_minimo, IFNULL(s.existencia, 0) AS stock_actual
      FROM producto p
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

// 3. Registrar una nueva cotización desde el formulario web
app.post('/api/cotizacion', async (req, res) => {
  const { nombre, tel, mail, linea, msg } = req.body;
  if (!nombre || !tel) {
    return res.status(400).json({ ok: false, error: 'Nombre y teléfono son obligatorios.' });
  }

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    // 1. Verificar si el cliente ya existe por teléfono
    let id_cliente;
    const [existentes] = await conn.query(
      'SELECT id_cliente FROM cliente WHERE telefono = ? LIMIT 1',
      [tel.trim()]
    );

    if (existentes.length > 0) {
      id_cliente = existentes[0].id_cliente;
    } else {
      // Insertar nuevo cliente potencial
      const [nuevo] = await conn.query(
        'INSERT INTO cliente (nombres_razon_social, telefono, correo, clasificacion) VALUES (?, ?, ?, "POTENCIAL")',
        [nombre.trim(), tel.trim(), mail ? mail.trim() : null]
      );
      id_cliente = nuevo.insertId;
    }

    // 2. Generar número correlativo de cotización
    const correlativo = 'COT-' + Date.now().toString().slice(-6);
    const hoy = new Date().toISOString().slice(0, 10);
    const validez = new Date(Date.now() + 15 * 86400000).toISOString().slice(0, 10); // 15 días de validez

    // 3. Insertar la cotización vinculada al cliente y tienda 1
    const [cotRes] = await conn.query(
      `INSERT INTO cotizacion (numero, id_cliente, id_usuario, id_tienda, fecha, fecha_validez, estado, total)
       VALUES (?, ?, 1, 1, ?, ?, 'VIGENTE', 0.00)`,
      [correlativo, id_cliente, hoy, validez]
    );

    // 4. Si hay mensaje o interés, registrar seguimiento
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

// 4. Listar cotizaciones para el panel
app.get('/api/cotizaciones', async (req, res) => {
  try {
    const query = `
      SELECT c.id_cotizacion, c.numero, c.fecha, c.fecha_validez, c.estado, c.total,
             cl.nombres_razon_social AS cliente, cl.telefono, cl.correo
      FROM cotizacion c
      JOIN cliente cl ON c.id_cliente = cl.id_cliente
      ORDER BY c.id_cotizacion DESC
    `;
    const [rows] = await pool.query(query);
    res.json({ ok: true, data: rows });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

// 5. Listar clientes
app.get('/api/clientes', async (req, res) => {
  try {
    const [rows] = await pool.query(
      'SELECT id_cliente, numero_documento, nombres_razon_social, telefono, correo, clasificacion FROM cliente ORDER BY id_cliente DESC'
    );
    res.json({ ok: true, data: rows });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

// 6. Resumen de KPIs para el administrador
app.get('/api/resumen', async (req, res) => {
  try {
    const [[prod]] = await pool.query('SELECT COUNT(*) AS total FROM producto WHERE activo = 1');
    const [[cli]] = await pool.query('SELECT COUNT(*) AS total FROM cliente');
    const [[cot]] = await pool.query('SELECT COUNT(*) AS total FROM cotizacion');
    const [[ped]] = await pool.query('SELECT COUNT(*) AS total FROM pedido');

    res.json({
      ok: true,
      kpis: {
        productos: prod.total,
        clientes: cli.total,
        cotizaciones: cot.total,
        pedidos: ped.total
      }
    });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

// Servir la página pública por defecto
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
